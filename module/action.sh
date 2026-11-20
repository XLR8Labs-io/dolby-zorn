#!/system/bin/sh
# Opens the Dolby control app.
#
# The upstream Lunaris module launched org.lunaris.dolby/.MainActivity, which
# does not exist in the APK - every launch failed with "Activity class does
# not exist". The real launcher is .ui.DolbyActivity.

am start -n org.lunaris.dolby/.ui.DolbyActivity 2>/dev/null && exit 0

# Fall back to whatever the package declares, in case a future build renames it.
monkey -p org.lunaris.dolby -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
