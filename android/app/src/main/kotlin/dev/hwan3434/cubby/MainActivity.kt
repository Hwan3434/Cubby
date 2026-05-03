package dev.hwan3434.cubby

import android.content.ContentResolver
import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
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
    }

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
                    else -> result.notImplemented()
                }
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
}
