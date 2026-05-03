package dev.hwan3434.cubby

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Intent
import android.content.IntentSender
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
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
    }

    /** 시스템 삭제 다이얼로그 결과를 기다리는 콜백. 한 번에 하나만. */
    private var pendingDeleteResult: MethodChannel.Result? = null
    /** 다이얼로그 동의 후 빈 폴더까지 정리하기 위해 보관. */
    private var pendingDeleteDir: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanCamera" -> scanCamera(result)
                    "latestCoverByBucket" -> {
                        val bucket = call.argument<String>("bucket")
                        val size = call.argument<Int>("size") ?: 160
                        if (bucket == null) {
                            result.error("bad_args", "bucket required", null)
                        } else {
                            latestCoverByBucket(bucket, size, result)
                        }
                    }
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
        val dir = pendingDeleteDir
        pendingDeleteResult = null
        pendingDeleteDir = null
        if (pending == null) return
        if (resultCode == Activity.RESULT_OK) {
            // 자산 삭제는 시스템이 처리. 빈 디렉토리는 우리가 정리.
            try { dir?.takeIf { it.exists() && it.isDirectory }?.delete() } catch (_: Exception) {}
            pending.success(true)
        } else {
            pending.success(false)
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

    /**
     * 주어진 bucket(앨범 이름)에서 가장 최근 image의 cover 썸네일을 직접
     * MediaStore에서 가져와 JPEG bytes로 반환한다. photo_manager가 같은
     * 프로세스 lifetime 안에서 가장 최근 1장을 빠뜨리는 한계를 우회.
     *
     * 반환: { id: Long, dateTaken: Long, bytes: ByteArray, data: String } 또는 null.
     */
    private fun latestCoverByBucket(
        bucket: String,
        size: Int,
        result: MethodChannel.Result,
    ) {
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            val uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            )
            val selection = "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} = ?"
            val selectionArgs = arrayOf(bucket)
            val sortOrder = "${MediaStore.Images.Media.DATE_TAKEN} DESC, " +
                "${MediaStore.Images.Media.DATE_ADDED} DESC"
            val cursor = resolver.query(
                uri, projection, selection, selectionArgs, sortOrder,
            )
            cursor?.use { c ->
                if (!c.moveToFirst()) {
                    result.success(null)
                    return
                }
                val id = c.getLong(c.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                val dateTakenMs = c.getLong(
                    c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN),
                )
                val dateAddedSec = c.getLong(
                    c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED),
                )
                val data = c.getString(
                    c.getColumnIndexOrThrow(MediaStore.Images.Media.DATA),
                )
                val itemUri = ContentUris.withAppendedId(uri, id)
                val bytes = loadThumbnailBytes(itemUri, size)
                if (bytes == null) {
                    result.success(null)
                    return
                }
                result.success(
                    mapOf(
                        "id" to id,
                        "dateTaken" to dateTakenMs,
                        "dateAdded" to dateAddedSec,
                        "data" to data,
                        "bytes" to bytes,
                    ),
                )
            } ?: run {
                result.success(null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "latestCoverByBucket failed", e)
            result.error("query_failed", e.message, null)
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
        try {
            val resolver: ContentResolver = applicationContext.contentResolver
            val uris = mutableListOf<Uri>()
            collectBucketUris(
                resolver,
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                bucket,
                uris,
            )
            collectBucketUris(
                resolver,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                bucket,
                uris,
            )
            val dir = findBucketDir(bucket)
            if (uris.isEmpty()) {
                // 자산이 0이면 빈 폴더만 정리.
                try { dir?.takeIf { it.exists() && it.isDirectory }?.delete() } catch (_: Exception) {}
                result.success(true)
                return
            }
            val pendingIntent = MediaStore.createDeleteRequest(resolver, uris)
            pendingDeleteResult = result
            pendingDeleteDir = dir
            try {
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    REQ_DELETE_ALBUM,
                    null, 0, 0, 0,
                )
            } catch (e: IntentSender.SendIntentException) {
                pendingDeleteResult = null
                pendingDeleteDir = null
                Log.e(TAG, "deleteAlbum sendIntent failed", e)
                result.error("send_failed", e.message, null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "deleteAlbum failed", e)
            result.error("delete_failed", e.message, null)
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

    /** Pictures/<bucket> 또는 DCIM/<bucket>/Movies/<bucket> 중 존재하는 디렉토리. */
    private fun findBucketDir(bucket: String): File? {
        val roots = listOf(
            Environment.DIRECTORY_PICTURES,
            Environment.DIRECTORY_DCIM,
            Environment.DIRECTORY_MOVIES,
        )
        for (root in roots) {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(root),
                bucket,
            )
            if (dir.exists() && dir.isDirectory) return dir
        }
        return null
    }
}
