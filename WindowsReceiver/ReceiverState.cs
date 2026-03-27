namespace UniversalControlWindowsReceiver;

internal sealed class ReceiverState
{
    private static readonly TimeSpan SyncTimeout = TimeSpan.FromMilliseconds(300);

    private readonly object gate = new();
    private readonly InputInjector injector;
    private readonly HashSet<ushort> pressedKeys = [];
    private readonly HashSet<ushort> loggedUnknownUsages = [];
    private readonly HashSet<byte> loggedUnknownButtons = [];

    private bool sessionActive;
    private byte modifierMask;
    private byte buttonMask;
    private DateTime lastSyncUtc = DateTime.MinValue;

    internal ReceiverState(InputInjector injector)
    {
        this.injector = injector;
    }

    internal void HandleSession(bool active)
    {
        lock (gate)
        {
            if (active)
            {
                ReleaseAllLocked();
                sessionActive = true;
                lastSyncUtc = DateTime.UtcNow;
                Console.WriteLine("Remote session active");
                return;
            }

            ReleaseAllLocked();
            sessionActive = false;
            lastSyncUtc = DateTime.MinValue;
            Console.WriteLine("Remote session inactive");
        }
    }

    internal void HandleKey(KeyPacket packet)
    {
        lock (gate)
        {
            if (!sessionActive)
            {
                return;
            }

            if (HidUsageMapper.TryGetModifierBit(packet.Usage, out var modifierBit))
            {
                SetModifierLocked(modifierBit, packet.IsDown);
                return;
            }

            if (!HidUsageMapper.TryGetScanCode(packet.Usage, out var mapping))
            {
                LogUnknownUsageLocked(packet.Usage);
                return;
            }

            if (packet.IsDown)
            {
                if (pressedKeys.Add(packet.Usage))
                {
                    injector.SendKey(mapping, true);
                }

                return;
            }

            if (pressedKeys.Remove(packet.Usage))
            {
                injector.SendKey(mapping, false);
            }
        }
    }

    internal void HandleButton(ButtonPacket packet)
    {
        lock (gate)
        {
            if (!sessionActive)
            {
                return;
            }

            var bit = ButtonMaskBit(packet.Button);
            if (bit == 0)
            {
                LogUnknownButtonLocked(packet.Button);
                return;
            }

            var isAlreadyDown = (buttonMask & bit) != 0;
            if (isAlreadyDown == packet.IsDown)
            {
                return;
            }

            injector.SendButton(packet.Button, packet.IsDown);
            if (packet.IsDown)
            {
                buttonMask |= bit;
            }
            else
            {
                buttonMask &= (byte)~bit;
            }
        }
    }

    internal void HandlePointer(PointerPacket packet)
    {
        lock (gate)
        {
            if (!sessionActive)
            {
                return;
            }

            injector.SendRelativePointer(packet.Dx, packet.Dy);
        }
    }

    internal void HandleWheel(WheelPacket packet)
    {
        lock (gate)
        {
            if (!sessionActive)
            {
                return;
            }

            injector.SendWheel(packet.DeltaY);
        }
    }

    internal void HandleSync(SyncPacket packet)
    {
        lock (gate)
        {
            if (!sessionActive)
            {
                return;
            }

            lastSyncUtc = DateTime.UtcNow;
            SyncModifiersLocked(packet.ModifierMask);
            SyncButtonsLocked(packet.ButtonMask);
            SyncKeysLocked(packet.PressedKeys);
        }
    }

    internal void CheckForSyncTimeout()
    {
        lock (gate)
        {
            if (!sessionActive || lastSyncUtc == DateTime.MinValue)
            {
                return;
            }

            if (DateTime.UtcNow - lastSyncUtc <= SyncTimeout)
            {
                return;
            }

            Console.Error.WriteLine("Sync timeout; releasing remote input state.");
            ReleaseAllLocked();
            sessionActive = false;
            lastSyncUtc = DateTime.MinValue;
        }
    }

    private void SyncKeysLocked(IEnumerable<ushort> desiredUsages)
    {
        var desired = new HashSet<ushort>(desiredUsages);

        foreach (var usage in pressedKeys.Except(desired).ToArray())
        {
            if (!HidUsageMapper.TryGetScanCode(usage, out var mapping))
            {
                continue;
            }

            injector.SendKey(mapping, false);
            pressedKeys.Remove(usage);
        }

        foreach (var usage in desired.Except(pressedKeys).ToArray())
        {
            if (!HidUsageMapper.TryGetScanCode(usage, out var mapping))
            {
                LogUnknownUsageLocked(usage);
                continue;
            }

            injector.SendKey(mapping, true);
            pressedKeys.Add(usage);
        }
    }

    private void SyncModifiersLocked(byte desiredMask)
    {
        for (var bit = 0; bit < 8; bit++)
        {
            var desired = (desiredMask & (1 << bit)) != 0;
            SetModifierLocked(bit, desired);
        }
    }

    private void SyncButtonsLocked(byte desiredMask)
    {
        for (var bit = 0; bit < 3; bit++)
        {
            var button = (byte)(bit + 1);
            var desired = (desiredMask & (1 << bit)) != 0;
            var current = (buttonMask & (1 << bit)) != 0;
            if (desired == current)
            {
                continue;
            }

            injector.SendButton(button, desired);
            if (desired)
            {
                buttonMask |= (byte)(1 << bit);
            }
            else
            {
                buttonMask &= (byte)~(1 << bit);
            }
        }
    }

    private void SetModifierLocked(int bit, bool shouldBeDown)
    {
        var mask = (byte)(1 << bit);
        var isDown = (modifierMask & mask) != 0;
        if (isDown == shouldBeDown)
        {
            return;
        }

        var usage = HidUsageMapper.ModifierUsageForBit(bit);
        if (!HidUsageMapper.TryGetScanCode(usage, out var mapping))
        {
            LogUnknownUsageLocked(usage);
            return;
        }

        injector.SendKey(mapping, shouldBeDown);
        if (shouldBeDown)
        {
            modifierMask |= mask;
        }
        else
        {
            modifierMask &= (byte)~mask;
        }
    }

    private void ReleaseAllLocked()
    {
        foreach (var usage in pressedKeys.ToArray())
        {
            if (!HidUsageMapper.TryGetScanCode(usage, out var mapping))
            {
                continue;
            }

            injector.SendKey(mapping, false);
        }

        pressedKeys.Clear();

        for (var bit = 0; bit < 8; bit++)
        {
            if ((modifierMask & (1 << bit)) == 0)
            {
                continue;
            }

            SetModifierLocked(bit, false);
        }

        for (var bit = 0; bit < 3; bit++)
        {
            if ((buttonMask & (1 << bit)) == 0)
            {
                continue;
            }

            injector.SendButton((byte)(bit + 1), false);
        }

        buttonMask = 0;
    }

    private void LogUnknownUsageLocked(ushort usage)
    {
        if (loggedUnknownUsages.Add(usage))
        {
            Console.Error.WriteLine($"Ignoring unsupported HID usage: 0x{usage:X4}");
        }
    }

    private void LogUnknownButtonLocked(byte button)
    {
        if (loggedUnknownButtons.Add(button))
        {
            Console.Error.WriteLine($"Ignoring unsupported mouse button: {button}");
        }
    }

    private static byte ButtonMaskBit(byte button) => button switch
    {
        1 => 1 << 0,
        2 => 1 << 1,
        3 => 1 << 2,
        _ => 0
    };
}
