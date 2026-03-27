using System.Net.Sockets;

namespace UniversalControlWindowsReceiver;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        CommandLineOptions options;
        try
        {
            options = CommandLineOptions.Parse(args);
        }
        catch (OperationCanceledException cancelled) when (cancelled.Message == CommandLineOptions.Usage)
        {
            Console.WriteLine(CommandLineOptions.Usage);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine(CommandLineOptions.Usage);
            return 1;
        }

        using var cancellationSource = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellationSource.Cancel();
        };

        using var udpClient = new UdpClient(options.ListenPort);
        var injector = new InputInjector();
        var receiverState = new ReceiverState(injector);

        Console.WriteLine($"Listening for remote input on UDP {options.ListenPort}");
        var timeoutTask = RunTimeoutMonitorAsync(receiverState, cancellationSource.Token);

        try
        {
            while (!cancellationSource.Token.IsCancellationRequested)
            {
                var result = await udpClient.ReceiveAsync(cancellationSource.Token);
                if (!Protocol.TryReadHeader(result.Buffer, out var sequence, out var kind, out var payload))
                {
                    Console.Error.WriteLine("Ignoring malformed packet header.");
                    continue;
                }

                _ = sequence;

                switch (kind)
                {
                    case PacketKind.Session:
                        if (Protocol.TryReadSession(payload, out var active))
                        {
                            receiverState.HandleSession(active);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed session packet.");
                        }
                        break;

                    case PacketKind.Key:
                        if (Protocol.TryReadKey(payload, out var keyPacket))
                        {
                            receiverState.HandleKey(keyPacket);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed key packet.");
                        }
                        break;

                    case PacketKind.Button:
                        if (Protocol.TryReadButton(payload, out var buttonPacket))
                        {
                            receiverState.HandleButton(buttonPacket);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed button packet.");
                        }
                        break;

                    case PacketKind.Pointer:
                        if (Protocol.TryReadPointer(payload, out var pointerPacket))
                        {
                            receiverState.HandlePointer(pointerPacket);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed pointer packet.");
                        }
                        break;

                    case PacketKind.Wheel:
                        if (Protocol.TryReadWheel(payload, out var wheelPacket))
                        {
                            receiverState.HandleWheel(wheelPacket);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed wheel packet.");
                        }
                        break;

                    case PacketKind.Sync:
                        if (Protocol.TryReadSync(payload, out var syncPacket))
                        {
                            receiverState.HandleSync(syncPacket);
                        }
                        else
                        {
                            Console.Error.WriteLine("Ignoring malformed sync packet.");
                        }
                        break;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            receiverState.HandleSession(active: false);
            cancellationSource.Cancel();

            try
            {
                await timeoutTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        return 0;
    }

    private static async Task RunTimeoutMonitorAsync(ReceiverState receiverState, CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(50));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            receiverState.CheckForSyncTimeout();
        }
    }
}
