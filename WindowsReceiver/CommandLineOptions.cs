namespace UniversalControlWindowsReceiver;

internal sealed class CommandLineOptions
{
    internal const int DefaultListenPort = 50001;
    internal const string Usage = "Usage: UniversalControlWindowsReceiver [--listen-port <port>]";

    internal int ListenPort { get; }

    private CommandLineOptions(int listenPort)
    {
        ListenPort = listenPort;
    }

    internal static CommandLineOptions Parse(string[] args)
    {
        var listenPort = DefaultListenPort;

        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--listen-port":
                    if (index + 1 >= args.Length)
                    {
                        throw new ArgumentException("Missing value for --listen-port.");
                    }

                    if (!int.TryParse(args[index + 1], out listenPort) || listenPort is < 1 or > 65535)
                    {
                        throw new ArgumentException($"Invalid port: {args[index + 1]}");
                    }

                    index++;
                    break;

                case "--help":
                case "-h":
                    throw new OperationCanceledException(Usage);

                default:
                    throw new ArgumentException($"Unexpected argument: {args[index]}");
            }
        }

        return new CommandLineOptions(listenPort);
    }
}
