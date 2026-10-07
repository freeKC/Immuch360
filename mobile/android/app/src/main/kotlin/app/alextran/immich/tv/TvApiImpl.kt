package app.alextran.immich.tv

import android.app.Activity
import android.app.AlertDialog
import android.text.InputType
import android.view.KeyEvent
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout

/**
 * TV detection and the native text dialog of the remote control layout. Set up with the engine of the app UI only:
 * the dialog needs this activity, and the background engines never show UI.
 */
class TvApiImpl(private val activity: Activity) : TvApi {
  override fun deviceInfo(): TvDeviceInfo =
    TvDeviceInfo(isTelevision = isTelevision(activity), isLowRamDevice = isLowRamDevice(activity))

  /**
   * A native dialog with an EditText: the Gboard TV keyboard can be driven with the remote there, unlike in a Flutter
   * text field (Flutter issue 177360). The result goes back once: the text on OK or Done, null on Cancel, Back or any
   * other dismissal, null at once when the activity is going away. What is typed is never logged (it may be a
   * password).
   */
  override fun editText(request: TvTextRequest, callback: (Result<String?>) -> Unit) {
    if (activity.isFinishing || activity.isDestroyed) {
      callback(Result.success(null))
      return
    }
    var answered = false
    fun answer(text: String?) {
      if (!answered) {
        answered = true
        callback(Result.success(text))
      }
    }

    val field =
      EditText(activity).apply {
        inputType = inputTypeOf(request.kind)
        imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = 1
        setText(request.text)
        setSelection(text.length)
      }
    val padding = (20 * activity.resources.displayMetrics.density).toInt()
    val container = FrameLayout(activity).apply { setPadding(padding, padding / 2, padding, 0) }
    container.addView(field)

    val dialog =
      AlertDialog.Builder(activity, android.R.style.Theme_DeviceDefault_Dialog_Alert)
        .setTitle(request.title)
        .setView(container)
        .setPositiveButton(request.okLabel) { _, _ -> answer(field.text.toString()) }
        .setNegativeButton(request.cancelLabel) { _, _ -> answer(null) }
        // Back, a touch outside, the activity going away: after the buttons, which answered first
        .setOnDismissListener { answer(null) }
        .create()
    field.setOnEditorActionListener { _, actionId, event ->
      val done =
        actionId == EditorInfo.IME_ACTION_DONE ||
          (event != null && event.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_UP)
      if (done) {
        answer(field.text.toString())
        dialog.dismiss()
      }
      done
    }
    dialog.setOnShowListener { field.requestFocus() }
    dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
    dialog.show()
  }

  private fun inputTypeOf(kind: TvTextKind): Int =
    when (kind) {
      TvTextKind.TEXT -> InputType.TYPE_CLASS_TEXT
      TvTextKind.URL -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
      TvTextKind.EMAIL -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
      TvTextKind.PASSWORD -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
      TvTextKind.NUMBER -> InputType.TYPE_CLASS_NUMBER
    }
}
