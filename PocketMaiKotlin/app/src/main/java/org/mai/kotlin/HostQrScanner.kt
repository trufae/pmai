@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Bundled on-device QR decoding: no Google Play Services model download. */
@Composable internal fun ScanHostQr(onClose: () -> Unit, onResult: (String) -> Unit) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var denied by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it; denied = !it
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        var message by remember { mutableStateOf("Point your camera at the host’s pmai connection QR code.") }
        var camera by remember { mutableStateOf<Camera?>(null) }
        var torch by remember { mutableStateOf(false) }
        Scaffold(Modifier.fillMaxSize(), topBar = {
            TopAppBar(title = { Text("Scan host QR") }, navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back to host setup") }
            }, actions = {
                if (camera?.cameraInfo?.hasFlashUnit() == true) IconButton(onClick = {
                    torch = !torch; camera?.cameraControl?.enableTorch(torch)
                }) { Icon(if (torch) Icons.Outlined.FlashOff else Icons.Outlined.FlashOn, if (torch) "Turn flash off" else "Turn flash on") }
            })
        }) { padding ->
            if (!granted) Column(Modifier.fillMaxSize().padding(padding), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                EmptyState(Icons.Outlined.PhotoCamera, "Camera access", if (denied) "Allow camera access to scan a host QR, or return to paste its connection link." else "Waiting for camera permission…")
                if (denied) TextButton(onClick = { permission.launch(Manifest.permission.CAMERA) }) { Text("Allow camera") }
                TextButton(onClick = onClose) { Text("Paste a link instead") }
            } else Column(Modifier.fillMaxSize().padding(padding)) {
                CameraQrPreview(Modifier.weight(1f).fillMaxWidth(), onCamera = { camera = it },
                    onMessage = { message = it }, onResult = onResult)
                Surface(tonalElevation = 4.dp) { Text(message, Modifier.fillMaxWidth().padding(24.dp), style = MaterialTheme.typography.bodyLarge) }
            }
        }
    }
}

@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
@Composable private fun CameraQrPreview(modifier: Modifier, onCamera: (Camera?) -> Unit,
    onMessage: (String) -> Unit, onResult: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val result by rememberUpdatedState(onResult)
    val message by rememberUpdatedState(onMessage)
    val cameraCallback by rememberUpdatedState(onCamera)
    val previewView = remember { PreviewView(context).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE } }
    AndroidView(factory = { previewView }, modifier = modifier)
    DisposableEffect(lifecycle, previewView) {
        val executor = Executors.newSingleThreadExecutor()
        val main = ContextCompat.getMainExecutor(context)
        val disposed = AtomicBoolean(false)
        val delivered = AtomicBoolean(false)
        val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
        val preview = Preview.Builder().build().apply { setSurfaceProvider(previewView.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var provider: ProcessCameraProvider? = null
        analysis.setAnalyzer(executor) { frame ->
            val image = frame.image
            if (image == null || disposed.get() || delivered.get()) { frame.close(); return@setAnalyzer }
            scanner.process(InputImage.fromMediaImage(image, frame.imageInfo.rotationDegrees))
                .addOnSuccessListener(main) { barcodes ->
                    if (!disposed.get()) {
                        val value = barcodes.firstNotNullOfOrNull { it.rawValue }?.trim()
                        if (value != null) {
                            if (value.startsWith("pmai-acp://connect/") && value.length <= 16384) {
                                if (delivered.compareAndSet(false, true)) result(value)
                            } else message("This QR is not a pmai host connection. Scan the QR shown by /remote serve.")
                        }
                    }
                }.addOnFailureListener(main) { error ->
                    if (!disposed.get()) message("Could not read this frame: ${error.localizedMessage}")
                }.addOnCompleteListener { frame.close() }
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (!disposed.get()) try {
                val value = future.get()
                provider = value
                val selector = if (value.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
                cameraCallback(value.bindToLifecycle(lifecycle, selector, preview, analysis))
            } catch (error: Exception) { message("Cannot open the camera: ${error.localizedMessage}. You can paste the connection link instead.") }
        }, main)
        onDispose {
            disposed.set(true)
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            scanner.close()
            executor.shutdown()
            cameraCallback(null)
        }
    }
}
