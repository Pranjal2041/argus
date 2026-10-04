package dev.universaltmux.android

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class WorkspaceParityDeviceTest {
    @Test fun fixtureScreensAndInteractions() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".qa") && (Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk")))
        val device = UiDevice.getInstance(instrumentation)
        val directory = File(context.getExternalFilesDir(null), "parity-screenshots").apply { mkdirs() }
        fun shot(name: String) { device.waitForIdle(); Thread.sleep(450); assertTrue(device.takeScreenshot(File(directory, "$name.png"))) }
        fun click(text: String) { assertTrue("Missing $text", device.wait(Until.hasObject(By.text(text)), 8000)); device.findObject(By.text(text)).click(); device.waitForIdle() }
        val intent = Intent().setClassName(context.packageName, "dev.universaltmux.android.ParityFixtureActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ActivityScenario.launch<Activity>(intent).use { scenario ->
            fun show(screen: Int) { scenario.onActivity { it.javaClass.getMethod("showScreen", Integer.TYPE).invoke(it, screen) }; device.waitForIdle(); Thread.sleep(900) }
            show(SCREEN_USAGE); shot("01-usage")
            click("Manage connections"); assertTrue(device.wait(Until.hasObject(By.text("Research cloud")), 5000)); shot("01b-connections")
            click("Edit"); shot("01c-connection-editor")
            device.findObject(By.clazz("android.widget.EditText").text("Research cloud")).text = "Mobile renamed account"
            click("Save connection"); assertTrue(device.wait(Until.hasObject(By.text("Mobile renamed account")), 5000)); shot("01d-connection-saved"); click("Done")
            click("Settings"); shot("02-usage-settings"); click("Done")
            click("Dismiss"); assertFalse(device.hasObject(By.text("Dismiss"))); shot("03-usage-dismissed")
            show(SCREEN_PLANNER); shot("04-planner")
            assertTrue(device.wait(Until.hasObject(By.desc("Add plan")), 4000)); device.findObject(By.desc("Add plan")).click()
            assertTrue(device.wait(Until.hasObject(By.text("New finish line")), 5000)); shot("05-planner-edit"); click("Cancel")
            show(SCREEN_WORKSPACE); shot("06-workspace")
            show(SCREEN_GIT); shot("07-git")
            click("src/workspace.kt"); assertTrue(device.wait(Until.hasObject(By.text("Diff")), 5000)); shot("08-git-diff"); click("Close")
            click("Pull requests"); assertTrue(device.wait(Until.hasObject(By.textContains("Shared workspace parity")), 5000)); shot("09-pull-requests")
            show(SCREEN_HISTORY); shot("10-history")
            show(SCREEN_DASHBOARDS); shot("11-dashboards")
            show(SCREEN_NOTEBOOKS); shot("12-notebooks")
            show(SCREEN_ARTIFACTS); shot("13-artifacts")
            click("Experiment report.pdf"); Thread.sleep(800); shot("14-artifact-pdf"); click("Next"); assertTrue(device.wait(Until.hasObject(By.text("2 / 2")), 5000)); shot("14b-artifact-page-two")
            show(SCREEN_JOURNAL); Thread.sleep(1500); shot("15-journal")
            show(SCREEN_WRAPPED); Thread.sleep(1500); shot("16-wrapped")
            show(31); assertTrue(device.wait(Until.hasObject(By.text("analysis.md")), 5000))
            assertTrue(device.wait(Until.hasObject(By.text("M")), 5000)); shot("17-files")
            device.findObject(By.desc("Search")).click(); click("File contents")
            device.findObject(By.clazz("android.widget.EditText")).text = "conditional"
            click("Search contents"); assertTrue(device.wait(Until.hasObject(By.text("/project/analysis.md:3")), 5000)); shot("17a-content-search")
            device.findObject(By.desc("Search")).click()
            click("analysis.md"); shot("17b-file-editor")
            show(30); Thread.sleep(1500); shot("18-render")
            click("Save PDF + source"); assertTrue(device.wait(Until.hasObject(By.text("Saved to artifacts")), 20000)); shot("19-render-saved")
            show(SCREEN_ARTIFACTS); Thread.sleep(1500); shot("20-render-artifact")
            click("Render.pdf"); Thread.sleep(800); shot("21-exported-render-pdf")
            val exported = File(context.filesDir, "workspace-blobs").listFiles()!!.filter { file ->
                file.inputStream().use { input -> String(input.readNBytes(5)) == "%PDF-" }
            }.maxBy { it.lastModified() }
            exported.copyTo(File(directory, "exported-render.pdf"), overwrite = true)
            PdfRenderer(ParcelFileDescriptor.open(exported, ParcelFileDescriptor.MODE_READ_ONLY)).use { pdf ->
                assertTrue("Long documents must retain all pages", pdf.pageCount > 2)
                repeat(pdf.pageCount) { index -> pdf.openPage(index).use { page ->
                    val bitmap = Bitmap.createBitmap(page.width, page.height, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val pixels = IntArray(bitmap.width * bitmap.height)
                    bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    assertTrue("Exported page ${index + 1} lost its content", pixels.count { Color.red(it) < 150 && Color.green(it) < 150 && Color.blue(it) < 150 } > 500)
                    bitmap.recycle()
                } }
            }
            click("View authored source"); assertTrue(device.wait(Until.hasObject(By.text("Authored source")), 5000))
            repeat(12) {
                if (!device.hasObject(By.text("## Result 45"))) device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5, device.displayWidth / 2, device.displayHeight / 5, 16)
            }
            assertTrue(device.hasObject(By.text("## Result 45"))); shot("22-authored-source")
        }
    }
}
