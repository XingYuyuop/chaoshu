package com.chaoshu.chaoshu

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val FOCUS_CHANNEL = "chaoshu/tv_focus"
    }

    private var focusChannel: MethodChannel? = null

    /** Flutter 侧告知：当前是否有输入框正在编辑 */
    private var captureDpad = false

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        focusChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOCUS_CHANNEL)
        focusChannel?.setMethodCallHandler { call, result ->
            if (call.method == "setCaptureDpad") {
                captureDpad = call.arguments == true
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    /**
     * Android TV / 电纸书端。
     *
     * 这台设备的系统层会把 D-pad 方向键和确认键吞掉，Flutter 收不到，
     * 表现为遥控器完全没反应。因此方向键和确认键统一由原生转发给 Flutter：
     *
     * - 非编辑状态：四向 + 确认键全部转发，用于界面导航和点按；
     * - 编辑状态：只转发上下键（切换输入框），左右键留给输入法移光标，
     *   确认键留给输入法选字母/候选词。
     */
    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (event == null || event.action != KeyEvent.ACTION_DOWN) {
            return super.dispatchKeyEvent(event)
        }
        val key = event.keyCode
        val isConfirm = key == KeyEvent.KEYCODE_DPAD_CENTER ||
            key == KeyEvent.KEYCODE_ENTER ||
            key == KeyEvent.KEYCODE_NUMPAD_ENTER

        if (isConfirm) {
            if (captureDpad) return super.dispatchKeyEvent(event)
            focusChannel?.invokeMethod("navigate", "confirm")
            return true
        }

        val dir = when (key) {
            KeyEvent.KEYCODE_DPAD_UP -> "up"
            KeyEvent.KEYCODE_DPAD_DOWN -> "down"
            KeyEvent.KEYCODE_DPAD_LEFT -> "left"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
            else -> return super.dispatchKeyEvent(event)
        }

        // 编辑输入框时，左右键交给输入法移动光标
        if (captureDpad && (key == KeyEvent.KEYCODE_DPAD_LEFT ||
                key == KeyEvent.KEYCODE_DPAD_RIGHT)) {
            return super.dispatchKeyEvent(event)
        }

        focusChannel?.invokeMethod("navigate", dir)
        return true
    }
}
