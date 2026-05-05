package dev.hwan3434.cubby

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Intent
import android.content.IntentSender
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MediaRefresh"
        private const val CHANNEL = "cubby/media_refresh"
        private const val MAX_FILES_PER_DIR = 200
        private const val REQ_DELETE_ALBUM = 4321

        // 일부 OEM은 변경 없는 파일에 scanFile 콜백을 늦게 부른다 — 이 시한 안에
        // 다 못 받으면 fallback path(직접 query)로 진행.
        private const val SCAN_LATCH_TIMEOUT_MS = 1500L
    }

    /** 시스템 삭제 다이얼로그 결과를 기다리는 콜백. 한 번에 하나만. */
    private var pendingDeleteResult: MethodChannel.Result? = null
    /**
     * 다이얼로그 동의 후 빈 폴더까지 정리하기 위해 보관. 한 앨범이라도 image는
     * Pictures/<name>/, video는 Movies/<name>/에 분산 저장되므로 List.
     */
    private var pendingDeleteDirs: List<File> = emptyList()

    // 외부 카메라가 백그라운드 동안 commit한 사진을 photo_manager가 못 보는
    // 함정 우회용. observer 등록만으로 MediaProvider가 우리 프로세스 binder
    // cache를 invalidate해 다음 쿼리가 fresh를 본다 — onChange 본문은 의미 없음.
    private var mediaObserverImage: ContentObserver? = null
    private var mediaObserverVideo: ContentObserver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerMediaObservers()
    }

    override fun onDestroy() {
        unregisterMediaObservers()
        super.onDestroy()
    }

    private fun registerMediaObservers() {
        val resolver = applicationContext.contentResolver
        val handler = Handler(Looper.getMainLooper())
        val imageObs = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {}
        }
        val videoObs = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {}
        }
        try {
            resolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, imageObs,
            )
            resolver.registerContentObserver(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, videoObs,
            )
            mediaObserverImage = imageObs
            mediaObserverVideo = videoObs
        } catch (e: Exception) {
            Log.e(TAG, "registerMediaObservers failed", e)
        }
    }

    private fun unregisterMediaObservers() {
        val resolver = applicationContext.contentResolver
        try { mediaObserverImage?.let { resolver.unregisterContentObserver(it) } } catch (_: Exception) {}
        try { mediaObserverVideo?.let { resolver.unregisterContentObserver(it) } } catch (_: Exception) {}
        mediaObserverImage = null
        mediaObserverVideo = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanCamera" -> scanCamera(result)
                    "recentByBucket" -> {
                        val bucket = call.argument<String>("bucket")
                        val limit = call.argument<Int>("limit") ?: 8
                        val size = call.argument<Int>("size") ?: 200
                        if (bucket == null) {
                            result.error("bad_args", "bucket required", null)
                        } else {
                            recentByBucket(bucket, limit, size, result)
                        }
                    }
                    "assetIdsByBucket" -> {
                        val bucket = call.argument<String>("bucket")
                        if (bucket == null) {
                            result.error("bad_args", "bucket required", null)
                        } else {
                            assetIdsByBucket(bucket, result)
                        }
                    }
                    "bucketSummary" -> bucketSummary(result)
                    "deleteAlbum" -> {
                        val bucket = call.argument<String>("bucket")
                        if (bucket == null) {
                            result.error("bad_args", "bucket required", null)
                        } else {
                            deleteAlbum(bucket, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_DELETE_ALBUM) return
        val pending = pendingDeleteResult
        val dirs = pendingDeleteDirs
        pendingDeleteResult = null
        pendingDeleteDirs = emptyList()
        if (pending == null) return
        if (resultCode == Activity.RESULT_OK) {
            // 자산 삭제는 시스템이 처리. 빈 디렉토리는 우리가 정리.
            deleteEmptyDirs(dirs)
            pending.success(true)
        } else {
            pending.success(false)
        }
    }

    private fun deleteEmptyDirs(dirs: List<File>) {
        for (d in dirs) {
            try {
                if (d.exists() && d.isDirectory) d.delete()
            } catch (_: Exception) {}
        }
    }

    /**
     * Force MediaProvider to commit pending inserts to our process so
     * photo_manager's next ContentResolver.query returns fresh data.
     *
     * Strategy:
     * 1. Walk DCIM and Pictures recursively, collect recent media files.
     * 2. MediaScannerConnection.scanFile against those concrete file paths
     *    (passing only the dir to scanFile is unreliable on some OEMs).
     * 3. Run a throwaway ContentResolver.query against
     *    MediaStore.Images.Media.EXTERNAL_CONTENT_URI to drain the binder
     *    cache before we hand control back to Dart.
     */
    // 외부 카메라가 raw file로만 저장한 자산을 MediaProvider에 commit시키기 위해
    // MediaScanner를 한 번 발동. cache invalidation은 [registerMediaObservers]가
    // 처리하므로 별도 wait 불필요.
    private fun scanCamera(result: MethodChannel.Result) {
        try {
            val roots = listOf(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
            )
            val files = mutableListOf<String>()
            for (root in roots) {
                files.addAll(collectMediaFiles(root))
            }
            if (files.isEmpty()) {
                drainBinderCache()
                result.success(null)
                return
            }
            val paths = files.toTypedArray()
            var pending = paths.size
            var firstError: String? = null
            for (path in paths) {
                try {
                    MediaScannerConnection.scanFile(
                        applicationContext,
                        arrayOf(path),
                        null,
                    ) { _, _ ->
                        synchronized(this) {
                            pending--
                            if (pending == 0) {
                                drainBinderCache()
                                if (firstError != null) {
                                    result.error("scan_failed", firstError, null)
                                } else {
                                    result.success(null)
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "scanCamera failed for $path", e)
                    synchronized(this) {
                        if (firstError == null) firstError = e.message
                        pending--
                        if (pending == 0) {
                            drainBinderCache()
                            result.error("scan_failed", firstError, null)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "scanCamera fatal", e)
            result.error("scan_fatal", e.message, null)
        }
    }

    /**
     * Walk the directory tree and return up to MAX_FILES_PER_DIR media files
     * (jpg/jpeg/png/heic/mp4) sorted by lastModified desc — most recent first.
     */
    private fun collectMediaFiles(root: File): List<String> {
        if (!root.exists() || !root.isDirectory) return emptyList()
        val out = mutableListOf<File>()
        val stack = ArrayDeque<File>()
        stack.addLast(root)
        while (stack.isNotEmpty() && out.size < MAX_FILES_PER_DIR) {
            val dir = stack.removeLast()
            val children = dir.listFiles() ?: continue
            for (child in children) {
                if (child.isDirectory) {
                    stack.addLast(child)
                } else if (isMediaFile(child)) {
                    out.add(child)
                }
            }
        }
        out.sortByDescending { it.lastModified() }
        return out.take(MAX_FILES_PER_DIR).map { it.absolutePath }
    }

    private fun isMediaFile(f: File): Boolean {
        val name = f.name.lowercase()
        return name.endsWith(".jpg") ||
            name.endsWith(".jpeg") ||
            name.endsWith(".png") ||
            name.endsWith(".heic") ||
            name.endsWith(".heif") ||
            name.endsWith(".mp4") ||
            name.endsWith(".mov") ||
            name.endsWith(".webp")
    }

    /**
     * Side-effect query against MediaStore to force the binder client to
     * round-trip to MediaProvider, draining any warm cache that would
     * otherwise return stale results to photo_manager's next call.
     * 결과 자체는 안 쓰고, query 한 번이 cache invalidation 트리거.
     */
    private fun drainBinderCache() {
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            resolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID),
                null,
                null,
                "${MediaStore.Images.Media.DATE_ADDED} DESC",
            )?.close()
            resolver.query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Video.Media._ID),
                null,
                null,
                "${MediaStore.Video.Media.DATE_ADDED} DESC",
            )?.close()
        } catch (e: Exception) {
            Log.e(TAG, "drainBinderCache failed", e)
        }
    }

    /// [bucket]에 속한 최근 자산 [limit]개를 image+video 통합으로. dateTaken이
    /// 0이면 dateAdded로 폴백.
    private fun recentByBucket(
        bucket: String,
        limit: Int,
        size: Int,
        result: MethodChannel.Result,
    ) {
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            val rows = mutableListOf<RecentRow>()
            queryRecent(resolver, bucket, limit, isVideo = false, out = rows)
            queryRecent(resolver, bucket, limit, isVideo = true, out = rows)
            rows.sortByDescending { it.effectiveTakenMs }
            val out = ArrayList<Map<String, Any?>>(limit)
            for (row in rows.take(limit)) {
                val uri = ContentUris.withAppendedId(row.collection, row.id)
                val bytes = loadThumbnailBytes(uri, size) ?: continue
                out.add(
                    mapOf(
                        "id" to row.id,
                        "isVideo" to row.isVideo,
                        "dateTaken" to row.dateTakenMs,
                        "dateAdded" to row.dateAddedSec,
                        "data" to row.data,
                        "bytes" to bytes,
                        "duration" to row.durationMs,
                    ),
                )
            }
            result.success(out)
        } catch (e: Exception) {
            Log.e(TAG, "recentByBucket failed", e)
            result.error("query_failed", e.message, null)
        }
    }

    private data class RecentRow(
        val id: Long,
        val isVideo: Boolean,
        val dateTakenMs: Long,
        val dateAddedSec: Long,
        val data: String?,
        val durationMs: Long,
    ) {
        val collection: Uri
            get() = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        val effectiveTakenMs: Long
            get() = if (dateTakenMs > 0) dateTakenMs else dateAddedSec * 1000
    }

    // pre-O는 Bundle의 QUERY_ARG_LIMIT 미지원이라 cursor 전체를 받고 take.
    private fun queryRecent(
        resolver: ContentResolver,
        bucket: String,
        limit: Int,
        isVideo: Boolean,
        out: MutableList<RecentRow>,
    ) {
        val uri = if (isVideo) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val projection = if (isVideo) {
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.DATA,
                MediaStore.Video.Media.DURATION,
            )
        } else {
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.DATA,
            )
        }
        val selection = "${MediaStore.MediaColumns.BUCKET_DISPLAY_NAME} = ?"
        val args = arrayOf(bucket)
        val sortOrder =
            "${MediaStore.MediaColumns.DATE_TAKEN} DESC, ${MediaStore.MediaColumns.DATE_ADDED} DESC"
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val bundle = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            }
            resolver.query(uri, projection, bundle, null)
        } else {
            resolver.query(uri, projection, selection, args, sortOrder)
        }
        cursor?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val takenCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
            val addedCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val dataCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            // 미존재 컬럼이면 -1 반환 — image projection엔 DURATION이 없으니 그대로 넘긴다.
            val durationCol = c.getColumnIndex(MediaStore.Video.Media.DURATION)
            var taken = 0
            while (c.moveToNext() && taken < limit) {
                out.add(
                    RecentRow(
                        id = c.getLong(idCol),
                        isVideo = isVideo,
                        dateTakenMs = c.getLong(takenCol),
                        dateAddedSec = c.getLong(addedCol),
                        data = c.getString(dataCol),
                        durationMs = if (durationCol >= 0) c.getLong(durationCol) else 0L,
                    ),
                )
                taken++
            }
        }
    }

    /// 모든 BUCKET_DISPLAY_NAME과 그 안의 자산 수 + 가장 최근 자산 ms epoch
    /// (DATE_TAKEN, 0이면 DATE_ADDED*1000으로 폴백)을 image+video 통합으로 반환.
    /// catalog 보강 + 앨범 정렬(최근 자산 desc)에 사용.
    private fun bucketSummary(result: MethodChannel.Result) {
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            val agg = HashMap<String, BucketAgg>()
            collectBucketAgg(resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, agg)
            collectBucketAgg(resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, agg)
            val out = agg.entries.map { (name, a) ->
                mapOf(
                    "name" to name,
                    "count" to a.count,
                    "lastTakenMs" to a.lastTakenMs,
                )
            }
            result.success(out)
        } catch (e: Exception) {
            Log.e(TAG, "bucketSummary failed", e)
            result.error("query_failed", e.message, null)
        }
    }

    private data class BucketAgg(var count: Int, var lastTakenMs: Long)

    private fun collectBucketAgg(
        resolver: ContentResolver,
        collection: Uri,
        out: HashMap<String, BucketAgg>,
    ) {
        resolver.query(
            collection,
            arrayOf(
                MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED,
            ),
            null,
            null,
            null,
        )?.use { c ->
            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val takenCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
            val addedCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            while (c.moveToNext()) {
                val name = c.getString(nameCol) ?: continue
                val taken = c.getLong(takenCol)
                val added = c.getLong(addedCol)
                val ms = if (taken > 0) taken else added * 1000
                val cur = out[name]
                if (cur == null) {
                    out[name] = BucketAgg(1, ms)
                } else {
                    cur.count += 1
                    if (ms > cur.lastTakenMs) cur.lastTakenMs = ms
                }
            }
        }
    }

    /// [bucket]에 속한 모든 자산의 (id, isVideo) 쌍을 image+video 통합으로 반환.
    /// photo_manager 자체 cache가 외부 삭제를 stale로 못 보는 동안에도 진실
    /// source가 되도록 — Dart 측 albumLive items에서 이 set에 없는 자산을 cull.
    private fun assetIdsByBucket(bucket: String, result: MethodChannel.Result) {
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            val ids = mutableListOf<Map<String, Any>>()
            collectIds(resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, bucket, false, ids)
            collectIds(resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, bucket, true, ids)
            result.success(ids)
        } catch (e: Exception) {
            Log.e(TAG, "assetIdsByBucket failed", e)
            result.error("query_failed", e.message, null)
        }
    }

    private fun collectIds(
        resolver: ContentResolver,
        collection: Uri,
        bucket: String,
        isVideo: Boolean,
        out: MutableList<Map<String, Any>>,
    ) {
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.BUCKET_DISPLAY_NAME} = ?",
            arrayOf(bucket),
            null,
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            while (c.moveToNext()) {
                out.add(mapOf("id" to c.getLong(idCol), "isVideo" to isVideo))
            }
        }
    }

    /** Q+ 는 loadThumbnail, 그 외는 BitmapFactory + 다운샘플. */
    private fun loadThumbnailBytes(uri: android.net.Uri, size: Int): ByteArray? {
        return try {
            val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                applicationContext.contentResolver.loadThumbnail(
                    uri, Size(size, size), null,
                )
            } else {
                applicationContext.contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            }
            if (bitmap == null) return null
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.e(TAG, "loadThumbnailBytes failed for $uri", e)
            null
        }
    }

    /**
     * bucket(앨범 이름) 안의 모든 image/video를 시스템 동의 다이얼로그로
     * 한 번에 삭제. R+ (API 30) 이상은 [MediaStore.createDeleteRequest] 의
     * IntentSender로 시스템이 묶음 삭제를 처리해주고, 그 이전 OS는
     * not-implemented로 떨어뜨린다 (cubby min sdk 21이지만 MediaStore 묶음
     * 삭제는 R 이상이라 그 이하는 사용자에게 의미있는 UX를 못 줌).
     *
     * 빈 디렉토리는 사용자가 다이얼로그를 허용한 직후 onActivityResult에서
     * 정리한다. [MethodChannel.Result]는 시스템 다이얼로그 결과까지 들고
     * 있다가 그때 success/false로 마무리.
     */
    private fun deleteAlbum(bucket: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("unsupported", "deleteAlbum requires Android R+", null)
            return
        }
        if (pendingDeleteResult != null) {
            result.error("busy", "another deleteAlbum is in progress", null)
            return
        }
        val dirs = findBucketDirs(bucket)
        val files = dirs.flatMap { collectMediaFiles(it) }
        if (files.isEmpty()) {
            // 디스크 잔여 파일 없음 — BUCKET으로만 한 번 시도.
            proceedWithUris(bucket, dirs, emptyList(), result)
            return
        }
        // scanFile callback이 (path, uri)를 돌려주는데, stale binder cache 안에서도
        // 정확한 Uri를 신뢰할 수 있는 유일한 출처. 다만 일부 OEM에서 metadata
        // 변경 없는 파일에 콜백을 늦게 발사하므로 timeout latch로 안전망.
        val collected = mutableListOf<Uri>()
        var pending = files.size
        var dispatched = false
        fun dispatch() {
            synchronized(this) {
                if (dispatched) return
                dispatched = true
            }
            runOnUiThread {
                proceedWithUris(bucket, dirs, collected.toList(), result)
            }
        }
        try {
            MediaScannerConnection.scanFile(
                applicationContext, files.toTypedArray(), null,
            ) { _, uri ->
                synchronized(this) {
                    if (uri != null) collected.add(uri)
                    pending--
                    if (pending == 0) dispatch()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteAlbum scanFile failed", e)
            result.error("scan_failed", e.message, null)
            return
        }
        // 콜백이 시한 안에 다 안 오면 fallback path로 진행.
        Handler(Looper.getMainLooper()).postDelayed({ dispatch() }, SCAN_LATCH_TIMEOUT_MS)
    }

    private fun proceedWithUris(
        bucket: String,
        dirs: List<File>,
        scannedUris: List<Uri>,
        result: MethodChannel.Result,
    ) {
        try {
            val resolver = applicationContext.contentResolver
            val uris = scannedUris.toMutableList()
            // scanFile이 못 잡은 자산은 file path 직접 lookup으로 보강.
            if (uris.isEmpty()) {
                val files = dirs.flatMap { collectMediaFiles(it) }
                for (path in files) {
                    lookupUriByData(resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, path)
                        ?.let(uris::add)
                        ?: lookupUriByData(resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, path)
                            ?.let(uris::add)
                }
            }
            // 그래도 없으면 BUCKET 검색.
            if (uris.isEmpty()) {
                collectBucketUris(
                    resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, bucket, uris,
                )
                collectBucketUris(
                    resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, bucket, uris,
                )
            }
            if (uris.isEmpty()) {
                deleteEmptyDirs(dirs)
                result.success(true)
                return
            }
            val pendingIntent = MediaStore.createDeleteRequest(resolver, uris)
            pendingDeleteResult = result
            pendingDeleteDirs = dirs
            try {
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    REQ_DELETE_ALBUM,
                    null, 0, 0, 0,
                )
            } catch (e: IntentSender.SendIntentException) {
                pendingDeleteResult = null
                pendingDeleteDirs = emptyList()
                Log.e(TAG, "deleteAlbum sendIntent failed", e)
                result.error("send_failed", e.message, null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteAlbum failed", e)
            result.error("delete_failed", e.message, null)
        }
    }

    private fun lookupUriByData(
        resolver: ContentResolver,
        collection: Uri,
        path: String,
    ): Uri? {
        return resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DATA} = ?",
            arrayOf(path),
            null,
        )?.use { c ->
            if (c.moveToFirst()) {
                val id = c.getLong(c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                ContentUris.withAppendedId(collection, id)
            } else {
                null
            }
        }
    }

    /** 주어진 [collection]에서 [bucket]에 속한 자산의 content uri를 누적. */
    private fun collectBucketUris(
        resolver: ContentResolver,
        collection: Uri,
        bucket: String,
        out: MutableList<Uri>,
    ) {
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.BUCKET_DISPLAY_NAME} = ?"
        val selectionArgs = arrayOf(bucket)
        resolver.query(collection, projection, selection, selectionArgs, null)
            ?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                while (c.moveToNext()) {
                    out.add(ContentUris.withAppendedId(collection, c.getLong(idCol)))
                }
            }
    }

    // 새 자산은 Pictures/<bucket>/만 사용하지만, 기존 분리 저장(Movies, DCIM)
    // 잔재 폴더가 남아 있을 수 있어 매치되는 모든 디렉토리를 반환.
    private fun findBucketDirs(bucket: String): List<File> {
        val roots = listOf(
            Environment.DIRECTORY_PICTURES,
            Environment.DIRECTORY_DCIM,
            Environment.DIRECTORY_MOVIES,
        )
        return roots
            .map { File(Environment.getExternalStoragePublicDirectory(it), bucket) }
            .filter { it.exists() && it.isDirectory }
    }
}
