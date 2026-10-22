package app.alextran.immich.pairing

import org.junit.Assert.assertEquals
import org.junit.Test

class QrScanApiImplTest {
  @Test
  fun aCodeReadIsHandedOverAsItIs() {
    val text = "http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA"
    assertEquals(QrScanResult(QrScanStatus.SCANNED, text), QrScanApiImpl.resultOf(text, missingCameraPermission = false))
  }

  @Test
  fun aClosedScannerIsCancelled() {
    assertEquals(QrScanResult(QrScanStatus.CANCELLED), QrScanApiImpl.resultOf(null, missingCameraPermission = false))
  }

  @Test
  fun aScannerWithoutTheCameraIsARefusal() {
    assertEquals(
      QrScanResult(QrScanStatus.PERMISSION_DENIED),
      QrScanApiImpl.resultOf(null, missingCameraPermission = true),
    )
  }

  @Test
  fun aCodeWinsOverAnyMissingPermissionFlag() {
    assertEquals(QrScanResult(QrScanStatus.SCANNED, "x"), QrScanApiImpl.resultOf("x", missingCameraPermission = true))
  }
}
