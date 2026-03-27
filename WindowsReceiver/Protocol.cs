using System.Buffers.Binary;

namespace UniversalControlWindowsReceiver;

internal enum PacketKind : byte
{
    Session = 1,
    Key = 2,
    Button = 3,
    Pointer = 4,
    Wheel = 5,
    Sync = 6
}

internal readonly record struct KeyPacket(ushort Usage, bool IsDown);
internal readonly record struct ButtonPacket(byte Button, bool IsDown);
internal readonly record struct PointerPacket(short Dx, short Dy);
internal readonly record struct WheelPacket(short DeltaY);
internal readonly record struct SyncPacket(byte ModifierMask, byte ButtonMask, ushort[] PressedKeys);

internal static class Protocol
{
    private const byte Version = 1;
    private const int HeaderLength = 10;

    internal static bool TryReadHeader(ReadOnlySpan<byte> packet, out uint sequence, out PacketKind kind, out ReadOnlySpan<byte> payload)
    {
        sequence = 0;
        kind = default;
        payload = default;

        if (packet.Length < HeaderLength)
        {
            return false;
        }

        if (packet[0] != (byte)'U' || packet[1] != (byte)'C' || packet[2] != (byte)'M' || packet[3] != (byte)'1')
        {
            return false;
        }

        if (packet[4] != Version)
        {
            return false;
        }

        sequence = BinaryPrimitives.ReadUInt32LittleEndian(packet.Slice(5, 4));
        var kindByte = packet[9];
        if (!Enum.IsDefined(typeof(PacketKind), kindByte))
        {
            return false;
        }

        kind = (PacketKind)kindByte;
        payload = packet[HeaderLength..];
        return true;
    }

    internal static bool TryReadSession(ReadOnlySpan<byte> payload, out bool active)
    {
        active = false;
        if (payload.Length != 1)
        {
            return false;
        }

        active = payload[0] != 0;
        return true;
    }

    internal static bool TryReadKey(ReadOnlySpan<byte> payload, out KeyPacket packet)
    {
        packet = default;
        if (payload.Length != 3)
        {
            return false;
        }

        packet = new KeyPacket(
            BinaryPrimitives.ReadUInt16LittleEndian(payload[..2]),
            payload[2] != 0
        );
        return true;
    }

    internal static bool TryReadButton(ReadOnlySpan<byte> payload, out ButtonPacket packet)
    {
        packet = default;
        if (payload.Length != 2)
        {
            return false;
        }

        packet = new ButtonPacket(payload[0], payload[1] != 0);
        return true;
    }

    internal static bool TryReadPointer(ReadOnlySpan<byte> payload, out PointerPacket packet)
    {
        packet = default;
        if (payload.Length != 4)
        {
            return false;
        }

        packet = new PointerPacket(
            BinaryPrimitives.ReadInt16LittleEndian(payload[..2]),
            BinaryPrimitives.ReadInt16LittleEndian(payload.Slice(2, 2))
        );
        return true;
    }

    internal static bool TryReadWheel(ReadOnlySpan<byte> payload, out WheelPacket packet)
    {
        packet = default;
        if (payload.Length != 2)
        {
            return false;
        }

        packet = new WheelPacket(BinaryPrimitives.ReadInt16LittleEndian(payload));
        return true;
    }

    internal static bool TryReadSync(ReadOnlySpan<byte> payload, out SyncPacket packet)
    {
        packet = default;
        if (payload.Length < 3)
        {
            return false;
        }

        var modifierMask = payload[0];
        var buttonMask = payload[1];
        var pressedKeyCount = payload[2];
        var expectedLength = 3 + (pressedKeyCount * 2);
        if (payload.Length != expectedLength)
        {
            return false;
        }

        var keys = new ushort[pressedKeyCount];
        for (var index = 0; index < pressedKeyCount; index++)
        {
            var offset = 3 + (index * 2);
            keys[index] = BinaryPrimitives.ReadUInt16LittleEndian(payload.Slice(offset, 2));
        }

        packet = new SyncPacket(modifierMask, buttonMask, keys);
        return true;
    }
}
