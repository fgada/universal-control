using System.Runtime.InteropServices;

namespace UniversalControlWindowsReceiver;

internal readonly record struct KeyboardRepeatConfiguration(TimeSpan InitialDelay, TimeSpan Interval)
{
    private const uint SpiGetKeyboardDelay = 0x0016;
    private const uint SpiGetKeyboardSpeed = 0x000A;

    private static readonly KeyboardRepeatConfiguration Default = new(
        TimeSpan.FromMilliseconds(500),
        TimeSpan.FromMilliseconds(33)
    );

    internal static KeyboardRepeatConfiguration Load()
    {
        uint keyboardDelay = 0;
        uint keyboardSpeed = 0;
        if (!SystemParametersInfo(SpiGetKeyboardDelay, 0, ref keyboardDelay, 0) ||
            !SystemParametersInfo(SpiGetKeyboardSpeed, 0, ref keyboardSpeed, 0))
        {
            return Default;
        }

        keyboardDelay = Math.Clamp(keyboardDelay, 0u, 3u);
        keyboardSpeed = Math.Clamp(keyboardSpeed, 0u, 31u);

        var initialDelay = TimeSpan.FromMilliseconds((keyboardDelay + 1) * 250);
        var repeatsPerSecond = 2.5 + (keyboardSpeed * ((30.0 - 2.5) / 31.0));
        var interval = TimeSpan.FromMilliseconds(Math.Max(1000.0 / repeatsPerSecond, 1.0));
        return new KeyboardRepeatConfiguration(initialDelay, interval);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);
}
