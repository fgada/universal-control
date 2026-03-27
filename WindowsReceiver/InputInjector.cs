using System.Runtime.InteropServices;

namespace UniversalControlWindowsReceiver;

internal sealed class InputInjector
{
    private const uint InputMouse = 0;
    private const uint InputKeyboard = 1;

    private const uint MouseEventMove = 0x0001;
    private const uint MouseEventLeftDown = 0x0002;
    private const uint MouseEventLeftUp = 0x0004;
    private const uint MouseEventRightDown = 0x0008;
    private const uint MouseEventRightUp = 0x0010;
    private const uint MouseEventMiddleDown = 0x0020;
    private const uint MouseEventMiddleUp = 0x0040;
    private const uint MouseEventWheel = 0x0800;

    private const uint KeyEventExtendedKey = 0x0001;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventScanCode = 0x0008;

    internal void SendKey(ScanCodeMapping mapping, bool isDown)
    {
        Send("keyboard", CreateKeyboardInput(mapping, isDown));
    }

    internal void SendKeyRepeat(ScanCodeMapping mapping)
    {
        // SendInput can drop the repeated character effect when release/press is
        // submitted as one batch, so emit them as distinct keyboard events.
        Send("keyboard repeat release", CreateKeyboardInput(mapping, isDown: false));
        Send("keyboard repeat press", CreateKeyboardInput(mapping, isDown: true));
    }

    internal void SendRelativePointer(short dx, short dy)
    {
        if (dx == 0 && dy == 0)
        {
            return;
        }

        var input = new INPUT
        {
            type = InputMouse,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = dx,
                    dy = dy,
                    mouseData = 0,
                    dwFlags = MouseEventMove,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };

        Send("pointer", input);
    }

    internal void SendWheel(short deltaY)
    {
        if (deltaY == 0)
        {
            return;
        }

        var scaledDelta = deltaY * 120;
        var input = new INPUT
        {
            type = InputMouse,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = 0,
                    dy = 0,
                    mouseData = unchecked((uint)scaledDelta),
                    dwFlags = MouseEventWheel,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };

        Send("wheel", input);
    }

    internal void SendButton(byte button, bool isDown)
    {
        var flags = button switch
        {
            1 when isDown => MouseEventLeftDown,
            1 => MouseEventLeftUp,
            2 when isDown => MouseEventRightDown,
            2 => MouseEventRightUp,
            3 when isDown => MouseEventMiddleDown,
            3 => MouseEventMiddleUp,
            _ => 0u
        };

        if (flags == 0)
        {
            return;
        }

        var input = new INPUT
        {
            type = InputMouse,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = 0,
                    dy = 0,
                    mouseData = 0,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };

        Send("button", input);
    }

    private static INPUT CreateKeyboardInput(ScanCodeMapping mapping, bool isDown)
    {
        var flags = KeyEventScanCode;
        if (mapping.Extended)
        {
            flags |= KeyEventExtendedKey;
        }

        if (!isDown)
        {
            flags |= KeyEventKeyUp;
        }

        return new INPUT
        {
            type = InputKeyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = 0,
                    wScan = mapping.ScanCode,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    private static void Send(string context, INPUT input)
    {
        var inputs = new[] { input };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != (uint)inputs.Length)
        {
            Console.Error.WriteLine($"SendInput failed for {context}: {Marshal.GetLastWin32Error()}");
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}
