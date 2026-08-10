#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/input-event-codes.h>
#include <linux/uinput.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { DEFAULT_PORT = 50001, HEADER_SIZE = 10, MAX_PACKET = 1024 };
enum { KIND_SESSION = 1, KIND_KEY, KIND_BUTTON, KIND_POINTER, KIND_WHEEL, KIND_SYNC };
static const int64_t SYNC_TIMEOUT_MS = 300;
static const int64_t SESSION_IDLE_TIMEOUT_MS = 5 * 60 * 1000;
static const int64_t REPEAT_DELAY_MS = 500;
static const int64_t REPEAT_INTERVAL_MS = 33;

typedef struct {
    int fd;
} Injector;

typedef struct {
    Injector *injector;
    bool session_active;
    bool awaiting_resync;
    uint8_t modifier_mask;
    uint8_t button_mask;
    bool pressed[UINT16_MAX + 1];
    bool unknown_usage_logged[UINT16_MAX + 1];
    bool unknown_button_logged[UINT8_MAX + 1];
    uint16_t repeat_order[UINT8_MAX + 1];
    size_t repeat_count;
    int repeating_usage;
    int64_t last_sync_ms;
    int64_t next_repeat_ms;
} ReceiverState;

static volatile sig_atomic_t stop_requested;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int64_t monotonic_ms(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static uint16_t read_u16_le(const uint8_t *data)
{
    return (uint16_t)data[0] | (uint16_t)((uint16_t)data[1] << 8);
}

static int16_t read_i16_le(const uint8_t *data)
{
    return (int16_t)read_u16_le(data);
}

static int linux_key_code(uint16_t usage)
{
    static const uint16_t codes[0xE8] = {
        [0x04] = KEY_A, [0x05] = KEY_B, [0x06] = KEY_C, [0x07] = KEY_D,
        [0x08] = KEY_E, [0x09] = KEY_F, [0x0A] = KEY_G, [0x0B] = KEY_H,
        [0x0C] = KEY_I, [0x0D] = KEY_J, [0x0E] = KEY_K, [0x0F] = KEY_L,
        [0x10] = KEY_M, [0x11] = KEY_N, [0x12] = KEY_O, [0x13] = KEY_P,
        [0x14] = KEY_Q, [0x15] = KEY_R, [0x16] = KEY_S, [0x17] = KEY_T,
        [0x18] = KEY_U, [0x19] = KEY_V, [0x1A] = KEY_W, [0x1B] = KEY_X,
        [0x1C] = KEY_Y, [0x1D] = KEY_Z,
        [0x1E] = KEY_1, [0x1F] = KEY_2, [0x20] = KEY_3, [0x21] = KEY_4,
        [0x22] = KEY_5, [0x23] = KEY_6, [0x24] = KEY_7, [0x25] = KEY_8,
        [0x26] = KEY_9, [0x27] = KEY_0,
        [0x28] = KEY_ENTER, [0x29] = KEY_ESC, [0x2A] = KEY_BACKSPACE,
        [0x2B] = KEY_TAB, [0x2C] = KEY_SPACE, [0x2D] = KEY_MINUS,
        [0x2E] = KEY_EQUAL, [0x2F] = KEY_LEFTBRACE, [0x30] = KEY_RIGHTBRACE,
        [0x31] = KEY_BACKSLASH, [0x33] = KEY_SEMICOLON, [0x34] = KEY_APOSTROPHE,
        [0x35] = KEY_GRAVE, [0x36] = KEY_COMMA, [0x37] = KEY_DOT,
        [0x38] = KEY_SLASH, [0x39] = KEY_CAPSLOCK,
        [0x3A] = KEY_F1, [0x3B] = KEY_F2, [0x3C] = KEY_F3, [0x3D] = KEY_F4,
        [0x3E] = KEY_F5, [0x3F] = KEY_F6, [0x40] = KEY_F7, [0x41] = KEY_F8,
        [0x42] = KEY_F9, [0x43] = KEY_F10, [0x44] = KEY_F11, [0x45] = KEY_F12,
        [0x46] = KEY_SYSRQ, [0x47] = KEY_SCROLLLOCK,
        [0x49] = KEY_INSERT, [0x4A] = KEY_HOME, [0x4B] = KEY_PAGEUP,
        [0x4C] = KEY_DELETE, [0x4D] = KEY_END, [0x4E] = KEY_PAGEDOWN,
        [0x4F] = KEY_RIGHT, [0x50] = KEY_LEFT, [0x51] = KEY_DOWN, [0x52] = KEY_UP,
        [0x53] = KEY_NUMLOCK, [0x54] = KEY_KPSLASH, [0x55] = KEY_KPASTERISK,
        [0x56] = KEY_KPMINUS, [0x57] = KEY_KPPLUS, [0x58] = KEY_KPENTER,
        [0x59] = KEY_KP1, [0x5A] = KEY_KP2, [0x5B] = KEY_KP3,
        [0x5C] = KEY_KP4, [0x5D] = KEY_KP5, [0x5E] = KEY_KP6,
        [0x5F] = KEY_KP7, [0x60] = KEY_KP8, [0x61] = KEY_KP9,
        [0x62] = KEY_KP0, [0x63] = KEY_KPDOT, [0x64] = KEY_102ND,
        [0x65] = KEY_COMPOSE, [0x8A] = KEY_HENKAN, [0x8B] = KEY_MUHENKAN,
        [0xE0] = KEY_LEFTCTRL, [0xE1] = KEY_LEFTSHIFT, [0xE2] = KEY_LEFTALT,
        [0xE3] = KEY_LEFTMETA, [0xE4] = KEY_RIGHTCTRL, [0xE5] = KEY_RIGHTSHIFT,
        [0xE6] = KEY_RIGHTALT, [0xE7] = KEY_RIGHTMETA
    };
    return usage < sizeof(codes) / sizeof(codes[0]) ? codes[usage] : 0;
}

static uint16_t modifier_usage(unsigned bit)
{
    return (uint16_t)(0xE0 + bit);
}

static int modifier_bit(uint16_t usage)
{
    return usage >= 0xE0 && usage <= 0xE7 ? usage - 0xE0 : -1;
}

static int write_all(int fd, const void *buffer, size_t size)
{
    const uint8_t *cursor = buffer;
    while (size > 0) {
        ssize_t written = write(fd, cursor, size);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        cursor += written;
        size -= (size_t)written;
    }
    return 0;
}

static int injector_emit(Injector *injector, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event events[2];
    memset(events, 0, sizeof(events));
    events[0].type = type;
    events[0].code = code;
    events[0].value = value;
    events[1].type = EV_SYN;
    events[1].code = SYN_REPORT;
    if (write_all(injector->fd, events, sizeof(events)) == 0) return 0;
    perror("write /dev/uinput");
    return -1;
}

static int injector_pointer(Injector *injector, int16_t dx, int16_t dy)
{
    struct input_event events[3];
    size_t count = 0;
    memset(events, 0, sizeof(events));
    if (dx != 0) events[count++] = (struct input_event){ .type = EV_REL, .code = REL_X, .value = dx };
    if (dy != 0) events[count++] = (struct input_event){ .type = EV_REL, .code = REL_Y, .value = dy };
    if (count == 0) return 0;
    events[count++] = (struct input_event){ .type = EV_SYN, .code = SYN_REPORT };
    if (write_all(injector->fd, events, count * sizeof(events[0])) != 0) {
        perror("write /dev/uinput");
        return -1;
    }
    return 0;
}

static int injector_init(Injector *injector)
{
    memset(injector, 0, sizeof(*injector));
    injector->fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    if (injector->fd < 0) {
        perror("open /dev/uinput");
        fprintf(stderr, "Ensure the uinput module is loaded and this user has write permission.\n");
        return -1;
    }
    if (ioctl(injector->fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(injector->fd, UI_SET_EVBIT, EV_REL) < 0 ||
        ioctl(injector->fd, UI_SET_RELBIT, REL_X) < 0 ||
        ioctl(injector->fd, UI_SET_RELBIT, REL_Y) < 0 ||
        ioctl(injector->fd, UI_SET_RELBIT, REL_WHEEL) < 0) {
        perror("configure /dev/uinput");
        close(injector->fd);
        injector->fd = -1;
        return -1;
    }
    for (unsigned usage = 0; usage <= UINT16_MAX; usage++) {
        int code = linux_key_code((uint16_t)usage);
        if (code != 0 && ioctl(injector->fd, UI_SET_KEYBIT, code) < 0) {
            perror("UI_SET_KEYBIT");
            close(injector->fd);
            injector->fd = -1;
            return -1;
        }
    }
    const int buttons[] = { BTN_LEFT, BTN_RIGHT, BTN_MIDDLE };
    for (size_t i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
        if (ioctl(injector->fd, UI_SET_KEYBIT, buttons[i]) < 0) {
            perror("UI_SET_KEYBIT");
            close(injector->fd);
            injector->fd = -1;
            return -1;
        }
    }

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = 0x0001;
    setup.id.version = 1;
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "Universal Control Receiver");
    if (ioctl(injector->fd, UI_DEV_SETUP, &setup) < 0 || ioctl(injector->fd, UI_DEV_CREATE) < 0) {
        perror("create uinput device");
        close(injector->fd);
        injector->fd = -1;
        return -1;
    }
    printf("Linux input injection initialized via /dev/uinput\n");
    return 0;
}

static void injector_destroy(Injector *injector)
{
    if (injector->fd >= 0) {
        ioctl(injector->fd, UI_DEV_DESTROY);
        close(injector->fd);
        injector->fd = -1;
    }
}

static int button_code(uint8_t button)
{
    switch (button) {
        case 1: return BTN_LEFT;
        case 2: return BTN_RIGHT;
        case 3: return BTN_MIDDLE;
        default: return 0;
    }
}

static uint8_t button_bit(uint8_t button)
{
    return button >= 1 && button <= 3 ? (uint8_t)(1u << (button - 1)) : 0;
}

static void log_unknown_usage(ReceiverState *state, uint16_t usage)
{
    if (!state->unknown_usage_logged[usage]) {
        state->unknown_usage_logged[usage] = true;
        fprintf(stderr, "Ignoring unsupported HID usage: 0x%04X\n", usage);
    }
}

static void send_key(ReceiverState *state, uint16_t usage, int value)
{
    int code = linux_key_code(usage);
    if (code == 0) log_unknown_usage(state, usage);
    else injector_emit(state->injector, EV_KEY, (uint16_t)code, value);
}

static void stop_repeat(ReceiverState *state)
{
    state->repeating_usage = -1;
    state->next_repeat_ms = 0;
}

static void repeat_pressed(ReceiverState *state, uint16_t usage)
{
    size_t found = state->repeat_count;
    for (size_t i = 0; i < state->repeat_count; i++) if (state->repeat_order[i] == usage) found = i;
    if (found < state->repeat_count) {
        memmove(&state->repeat_order[found], &state->repeat_order[found + 1],
                (state->repeat_count - found - 1) * sizeof(state->repeat_order[0]));
        state->repeat_count--;
    }
    if (state->repeat_count < sizeof(state->repeat_order) / sizeof(state->repeat_order[0]))
        state->repeat_order[state->repeat_count++] = usage;
    state->repeating_usage = usage;
    state->next_repeat_ms = monotonic_ms() + REPEAT_DELAY_MS;
}

static void repeat_released(ReceiverState *state, uint16_t usage)
{
    for (size_t i = 0; i < state->repeat_count; i++) {
        if (state->repeat_order[i] == usage) {
            memmove(&state->repeat_order[i], &state->repeat_order[i + 1],
                    (state->repeat_count - i - 1) * sizeof(state->repeat_order[0]));
            state->repeat_count--;
            break;
        }
    }
    if (state->repeating_usage != usage) return;
    while (state->repeat_count > 0) {
        uint16_t fallback = state->repeat_order[state->repeat_count - 1];
        if (state->pressed[fallback]) {
            state->repeating_usage = fallback;
            state->next_repeat_ms = monotonic_ms() + REPEAT_DELAY_MS;
            return;
        }
        state->repeat_count--;
    }
    stop_repeat(state);
}

static void set_modifier(ReceiverState *state, unsigned bit, bool down)
{
    uint8_t mask = (uint8_t)(1u << bit);
    if (((state->modifier_mask & mask) != 0) == down) return;
    send_key(state, modifier_usage(bit), down ? 1 : 0);
    if (down) state->modifier_mask |= mask;
    else state->modifier_mask &= (uint8_t)~mask;
}

static void release_all(ReceiverState *state)
{
    stop_repeat(state);
    state->repeat_count = 0;
    for (unsigned usage = 0; usage <= UINT16_MAX; usage++) {
        if (state->pressed[usage]) send_key(state, (uint16_t)usage, 0);
        state->pressed[usage] = false;
    }
    for (unsigned bit = 0; bit < 8; bit++) if (state->modifier_mask & (1u << bit)) set_modifier(state, bit, false);
    for (uint8_t button = 1; button <= 3; button++)
        if (state->button_mask & button_bit(button)) injector_emit(state->injector, EV_KEY, button_code(button), 0);
    state->button_mask = 0;
}

static void handle_session(ReceiverState *state, bool active)
{
    release_all(state);
    state->session_active = active;
    state->last_sync_ms = active ? monotonic_ms() : 0;
    state->awaiting_resync = false;
    printf("Remote session %s\n", active ? "active" : "inactive");
}

static void handle_key(ReceiverState *state, uint16_t usage, bool down)
{
    if (!state->session_active || state->awaiting_resync) return;
    int bit = modifier_bit(usage);
    if (bit >= 0) { set_modifier(state, (unsigned)bit, down); return; }
    if (linux_key_code(usage) == 0) { log_unknown_usage(state, usage); return; }
    if (down && !state->pressed[usage]) {
        state->pressed[usage] = true;
        send_key(state, usage, 1);
        repeat_pressed(state, usage);
    } else if (!down && state->pressed[usage]) {
        state->pressed[usage] = false;
        send_key(state, usage, 0);
        repeat_released(state, usage);
    }
}

static void handle_button(ReceiverState *state, uint8_t button, bool down)
{
    if (!state->session_active || state->awaiting_resync) return;
    uint8_t bit = button_bit(button);
    if (bit == 0) {
        if (!state->unknown_button_logged[button]) {
            state->unknown_button_logged[button] = true;
            fprintf(stderr, "Ignoring unsupported mouse button: %u\n", button);
        }
        return;
    }
    if (((state->button_mask & bit) != 0) == down) return;
    injector_emit(state->injector, EV_KEY, (uint16_t)button_code(button), down ? 1 : 0);
    if (down) state->button_mask |= bit;
    else state->button_mask &= (uint8_t)~bit;
}

static void handle_sync(ReceiverState *state, const uint8_t *payload, size_t length)
{
    if (!state->session_active || length < 3 || length != 3u + (size_t)payload[2] * 2u) return;
    bool desired[UINT16_MAX + 1] = { false };
    for (unsigned i = 0; i < payload[2]; i++) desired[read_u16_le(payload + 3 + i * 2)] = true;
    if (state->awaiting_resync) printf("Sync restored; resuming remote session.\n");
    state->last_sync_ms = monotonic_ms();
    state->awaiting_resync = false;
    for (unsigned bit = 0; bit < 8; bit++) set_modifier(state, bit, (payload[0] & (1u << bit)) != 0);
    for (uint8_t button = 1; button <= 3; button++) handle_button(state, button, (payload[1] & button_bit(button)) != 0);
    for (unsigned usage = 0; usage <= UINT16_MAX; usage++) {
        if (state->pressed[usage] != desired[usage]) handle_key(state, (uint16_t)usage, desired[usage]);
    }
}

static void check_timers(ReceiverState *state)
{
    int64_t now = monotonic_ms();
    if (state->session_active && state->last_sync_ms != 0) {
        int64_t elapsed = now - state->last_sync_ms;
        if (elapsed > SYNC_TIMEOUT_MS && !state->awaiting_resync) {
            fprintf(stderr, "Sync timeout; releasing remote input state and waiting for resync.\n");
            release_all(state);
            state->awaiting_resync = true;
        }
        if (elapsed > SESSION_IDLE_TIMEOUT_MS) {
            fprintf(stderr, "Session idle timeout; abandoning remote session.\n");
            state->session_active = false;
            state->last_sync_ms = 0;
            state->awaiting_resync = false;
        }
    }
    if (state->session_active && state->repeating_usage >= 0 && now >= state->next_repeat_ms) {
        uint16_t usage = (uint16_t)state->repeating_usage;
        if (state->pressed[usage]) {
            send_key(state, usage, 2);
            state->next_repeat_ms = now + REPEAT_INTERVAL_MS;
        } else stop_repeat(state);
    }
}

static void process_packet(ReceiverState *state, const uint8_t *packet, size_t length)
{
    if (length < HEADER_SIZE || memcmp(packet, "UCM1", 4) != 0 || packet[4] != 1 ||
        packet[9] < KIND_SESSION || packet[9] > KIND_SYNC) {
        fprintf(stderr, "Ignoring malformed packet header.\n");
        return;
    }
    const uint8_t *payload = packet + HEADER_SIZE;
    size_t payload_length = length - HEADER_SIZE;
    switch (packet[9]) {
        case KIND_SESSION:
            if (payload_length == 1) handle_session(state, payload[0] != 0);
            else fprintf(stderr, "Ignoring malformed session packet.\n");
            break;
        case KIND_KEY:
            if (payload_length == 3) handle_key(state, read_u16_le(payload), payload[2] != 0);
            else fprintf(stderr, "Ignoring malformed key packet.\n");
            break;
        case KIND_BUTTON:
            if (payload_length == 2) handle_button(state, payload[0], payload[1] != 0);
            else fprintf(stderr, "Ignoring malformed button packet.\n");
            break;
        case KIND_POINTER:
            if (payload_length == 4 && state->session_active && !state->awaiting_resync)
                injector_pointer(state->injector, read_i16_le(payload), read_i16_le(payload + 2));
            else if (payload_length != 4) fprintf(stderr, "Ignoring malformed pointer packet.\n");
            break;
        case KIND_WHEEL:
            if (payload_length == 2 && state->session_active && !state->awaiting_resync) {
                int16_t delta = read_i16_le(payload);
                if (delta != 0) injector_emit(state->injector, EV_REL, REL_WHEEL, delta);
            } else if (payload_length != 2) fprintf(stderr, "Ignoring malformed wheel packet.\n");
            break;
        case KIND_SYNC:
            if (payload_length >= 3 && payload_length == 3u + (size_t)payload[2] * 2u)
                handle_sync(state, payload, payload_length);
            else fprintf(stderr, "Ignoring malformed sync packet.\n");
            break;
    }
}

static void print_addresses(int port)
{
    struct ifaddrs *interfaces;
    if (getifaddrs(&interfaces) != 0) { perror("getifaddrs"); return; }
    printf("Local IPv4 addresses:\n");
    for (struct ifaddrs *item = interfaces; item != NULL; item = item->ifa_next) {
        if (item->ifa_addr == NULL || item->ifa_addr->sa_family != AF_INET ||
            !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK)) continue;
        char address[INET_ADDRSTRLEN];
        struct sockaddr_in *ipv4 = (struct sockaddr_in *)item->ifa_addr;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, address, sizeof(address))) printf("  %s (%s)\n", address, item->ifa_name);
    }
    freeifaddrs(interfaces);
    printf("Use one from macOS with --target-host <IP> --target-port %d\n", port);
}

static int parse_port(int argc, char **argv)
{
    int port = DEFAULT_PORT;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("Usage: %s [--listen-port <port>]\n", argv[0]);
            return 0;
        }
        if (strcmp(argv[i], "--listen-port") != 0 || ++i >= argc) return -1;
        char *end = NULL;
        long value = strtol(argv[i], &end, 10);
        if (*argv[i] == '\0' || *end != '\0' || value < 1 || value > 65535) return -1;
        port = (int)value;
    }
    return port;
}

int main(int argc, char **argv)
{
    int port = parse_port(argc, argv);
    if (port == 0) return EXIT_SUCCESS;
    if (port < 0) {
        fprintf(stderr, "Usage: %s [--listen-port <port>]\n", argv[0]);
        return EXIT_FAILURE;
    }
    Injector injector = { .fd = -1 };
    if (injector_init(&injector) != 0) return EXIT_FAILURE;
    int socket_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0) { perror("socket"); injector_destroy(&injector); return EXIT_FAILURE; }
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        perror("bind"); close(socket_fd); injector_destroy(&injector); return EXIT_FAILURE;
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);

    ReceiverState state;
    memset(&state, 0, sizeof(state));
    state.injector = &injector;
    state.repeating_usage = -1;
    printf("Keyboard repeat configured: delay=%lldms interval=%lldms\n",
           (long long)REPEAT_DELAY_MS, (long long)REPEAT_INTERVAL_MS);
    print_addresses(port);
    printf("Listening for remote input on UDP %d\n", port);

    uint8_t packet[MAX_PACKET];
    struct pollfd poll_descriptor = { .fd = socket_fd, .events = POLLIN };
    while (!stop_requested) {
        int result = poll(&poll_descriptor, 1, 10);
        if (result < 0) {
            if (errno == EINTR) continue;
            perror("poll"); break;
        }
        if (result > 0 && (poll_descriptor.revents & POLLIN)) {
            ssize_t length = recv(socket_fd, packet, sizeof(packet), 0);
            if (length < 0) { if (errno != EINTR) perror("recv"); }
            else process_packet(&state, packet, (size_t)length);
        }
        check_timers(&state);
    }
    handle_session(&state, false);
    close(socket_fd);
    injector_destroy(&injector);
    return EXIT_SUCCESS;
}
