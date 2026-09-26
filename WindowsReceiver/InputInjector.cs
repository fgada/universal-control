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

    private const ushort VirtualKeyNumLock = 0x90;
    private const ushort VirtualKeyControl = 0x11;
    private const ushort VirtualKeyV = 0x56;

    private const uint ClipboardFormatUnicodeText = 13;
    private const uint GlobalMemoryMoveable = 0x0002;
    private const int ClipboardOpenAttempts = 10;
    private static readonly TimeSpan ClipboardRetryDelay = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan NumLockSettleTime = TimeSpan.FromMilliseconds(500);
    private DateTime lastNumLockToggleUtc = DateTime.MinValue;

    // Typing text as KEYEVENTF_UNICODE input drops symbols when an IME is active
    // or input arrives too quickly, so paste through the clipboard instead.
    internal bool SendText(string text)
    {
        // Text from macOS uses LF line endings; many Windows apps expect CRLF.
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r\n");
        if (!TrySetClipboardText(normalized))
        {
            Console.Error.WriteLine($"Failed to write text to the clipboard: {Marshal.GetLastWin32Error()}");
            return false;
        }

        Send("paste", [
            CreateVirtualKeyInput(VirtualKeyControl, 0),
            CreateVirtualKeyInput(VirtualKeyV, 0),
            CreateVirtualKeyInput(VirtualKeyV, KeyEventKeyUp),
            CreateVirtualKeyInput(VirtualKeyControl, KeyEventKeyUp)
        ]);
        return true;
    }

    private static bool TrySetClipboardText(string text)
    {
        // Another process may briefly hold the clipboard open.
        var opened = false;
        for (var attempt = 0; attempt < ClipboardOpenAttempts && !opened; attempt++)
        {
            opened = OpenClipboard(IntPtr.Zero);
            if (!opened)
            {
                Thread.Sleep(ClipboardRetryDelay);
            }
        }

        if (!opened)
        {
            return false;
        }

        try
        {
            if (!EmptyClipboard())
            {
                return false;
            }

            var byteCount = (text.Length + 1) * sizeof(char);
            var handle = GlobalAlloc(GlobalMemoryMoveable, (UIntPtr)byteCount);
            if (handle == IntPtr.Zero)
            {
                return false;
            }

            var pointer = GlobalLock(handle);
            if (pointer == IntPtr.Zero)
            {
                GlobalFree(handle);
                return false;
            }

            Marshal.Copy(text.ToCharArray(), 0, pointer, text.Length);
            Marshal.WriteInt16(pointer, text.Length * sizeof(char), 0);
            GlobalUnlock(handle);

            // The clipboard owns the memory only when SetClipboardData succeeds.
            if (SetClipboardData(ClipboardFormatUnicodeText, handle) == IntPtr.Zero)
            {
                GlobalFree(handle);
                return false;
            }

            return true;
        }
        finally
        {
            CloseClipboard();
        }
    }

    internal void SendKey(KeyboardMapping mapping, bool isDown)
    {
        if (isDown && mapping.RequiresNumLock)
        {
            EnsureNumLockOn();
        }

        Send("keyboard", CreateKeyboardInput(mapping, isDown));
    }

    // Mac keyboards have no Num Lock state, so keypad digits must not turn into
    // navigation keys when Windows happens to have Num Lock off.
    private void EnsureNumLockOn()
    {
        // The toggle state is updated asynchronously after SendInput; skip the
        // check briefly so rapid keypresses do not toggle Num Lock back off.
        var now = DateTime.UtcNow;
        if (now - lastNumLockToggleUtc < NumLockSettleTime)
        {
            return;
        }

        if ((GetKeyState(VirtualKeyNumLock) & 0x0001) != 0)
        {
            return;
        }

        Send("num lock", [
            CreateVirtualKeyInput(VirtualKeyNumLock, KeyEventExtendedKey),
            CreateVirtualKeyInput(VirtualKeyNumLock, KeyEventExtendedKey | KeyEventKeyUp)
        ]);
        lastNumLockToggleUtc = now;
    }

    internal void SendKeyRepeat(KeyboardMapping mapping)
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

    private static INPUT CreateKeyboardInput(KeyboardMapping mapping, bool isDown)
    {
        var flags = mapping.UsesVirtualKey ? 0u : KeyEventScanCode;
        if (!mapping.UsesVirtualKey && mapping.Extended)
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
                    wVk = mapping.UsesVirtualKey ? mapping.Code : (ushort)0,
                    wScan = mapping.UsesVirtualKey ? (ushort)0 : mapping.Code,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    private static INPUT CreateVirtualKeyInput(ushort virtualKey, uint flags)
    {
        return new INPUT
        {
            type = InputKeyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = virtualKey,
                    wScan = 0,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    private static void Send(string context, INPUT input)
    {
        Send(context, [input]);
    }

    private static void Send(string context, INPUT[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != (uint)inputs.Length)
        {
            Console.Error.WriteLine($"SendInput failed for {context}: {Marshal.GetLastWin32Error()}");
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr hMem);

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
