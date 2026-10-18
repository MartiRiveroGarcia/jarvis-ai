package io.github.martiriverogarcia.jarvis

import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterShellArgs

/**
 * The Android digital-assistant surface, started by long-pressing Power once
 * Jarvis is the selected assistant. It runs its own Flutter engine with the
 * assistant-only entrypoint (lib/assistant_main.dart), never the normal app.
 *
 * It may be shown over the lock screen, so:
 * - only an ACTION_ASSIST launch while Jarvis holds the assistant role is
 *   served; anything else finishes before any Dart code runs;
 * - the only thing read from the launching Intent is its action. Every
 *   FlutterActivity hook that would read Intent extras or data is overridden;
 * - every session ends through [endSession], which removes the lock-screen
 *   capability together with the Activity and its task.
 */
class AssistantActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val valid = isAssistantInvocation(intent)
        if (valid && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            // Before the window is shown, so a locked phone shows it at once.
            setShowWhenLocked(true)
        }
        super.onCreate(savedInstanceState)
        if (!valid) {
            // Before onStart: the Dart entrypoint never runs.
            endSession()
        }
    }

    override fun onNewIntent(intent: Intent) {
        if (!isAssistantInvocation(intent)) {
            return // the current session, if any, is left untouched
        }
        super.onNewIntent(intent)
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) {
            // Backgrounded, covered or the screen turned off: the session is
            // over, and no instance may linger to reappear over the lock screen.
            endSession()
        }
    }

    /** SystemNavigator.pop(), from Close or Back at the root, ends the session. */
    override fun popSystemNavigator(): Boolean {
        endSession()
        return true
    }

    /** True once [endSession] has run: a session ends exactly once. */
    private var sessionEnding = false

    /** The single way an assistant session ends. Later calls are no-ops. */
    private fun endSession() {
        if (sessionEnding) {
            return // e.g. onStop after Close or Back already ended it
        }
        sessionEnding = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
        }
        finishAndRemoveTask()
    }

    /** Only the action is read; extras, data and clip data never are. */
    private fun isAssistantInvocation(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_ASSIST && assistantRoleHeld()

    private fun assistantRoleHeld(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_ASSISTANT)

    // --- Fixed launch configuration --------------------------------------------
    // FlutterActivity's defaults read these from the launching Intent. Any app
    // can send ACTION_ASSIST, so none of them may come from it.

    override fun getDartEntrypointFunctionName(): String = DART_ENTRYPOINT

    override fun getDartEntrypointLibraryUri(): String = DART_LIBRARY

    override fun getDartEntrypointArgs(): List<String>? = null

    override fun getInitialRoute(): String? = null

    override fun shouldHandleDeeplinking(): Boolean = false

    override fun getCachedEngineId(): String? = null

    override fun getCachedEngineGroupId(): String? = null

    override fun shouldDestroyEngineWithHost(): Boolean = true

    // Transparent window (AssistantTheme is translucent): only the assistant
    // panel is drawn over whatever is below, including the lock screen.
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun shouldRestoreAndSaveState(): Boolean = false

    override fun getFlutterShellArgs(): FlutterShellArgs = FlutterShellArgs(emptyArray<String>())

    override fun getAppBundlePath(): String = FlutterInjector.instance().flutterLoader().findAppBundlePath()

    private companion object {
        const val DART_ENTRYPOINT = "assistantMain"
        const val DART_LIBRARY = "package:jarvis/assistant_main.dart"
    }
}
