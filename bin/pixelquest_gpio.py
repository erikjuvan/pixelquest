"""GPIO reset-button support for the Pixel Quest daemon."""

import threading
import time
from datetime import timedelta

# BCM 26 is physical header pin 37.
RESET_BUTTON_GPIO = 26
RESET_BUTTON_DEBOUNCE_SECONDS = 0.05


def start_reset_button(reset_console, log):
    """Start the active-low reset button listener and return its thread."""
    stop_event = threading.Event()

    def listen():
        chip = None
        line = None
        request = None

        try:
            import gpiod

            chip = gpiod.Chip("/dev/gpiochip0")
        except (ImportError, OSError) as error:
            log(f"Reset button unavailable: {error}")
            return

        try:
            # Raspberry Pi OS Bookworm provides libgpiod v1; current Arch
            # provides v2.  Their Python APIs differ, so support both.
            if hasattr(chip, "get_line"):
                line = chip.get_line(RESET_BUTTON_GPIO)
                line.request(
                    consumer="pixelquest-reset",
                    type=gpiod.LINE_REQ_EV_FALLING_EDGE,
                    flags=gpiod.LINE_REQ_FLAG_BIAS_PULL_UP,
                )

                def wait_for_press():
                    if not line.event_wait(sec=1):
                        return False
                    line.event_read()
                    return True

            else:
                request = chip.request_lines(
                    consumer="pixelquest-reset",
                    config={
                        RESET_BUTTON_GPIO: gpiod.LineSettings(
                            direction=gpiod.line.Direction.INPUT,
                            edge_detection=gpiod.line.Edge.FALLING,
                            bias=gpiod.line.Bias.PULL_UP,
                        )
                    },
                )

                def wait_for_press():
                    if not request.wait_edge_events(timedelta(seconds=1)):
                        return False
                    request.read_edge_events()
                    return True

            log(
                f"Reset button listening on BCM GPIO {RESET_BUTTON_GPIO} "
                "(active-low)"
            )
            last_press = 0.0

            while not stop_event.is_set():
                if not wait_for_press():
                    continue

                now = time.monotonic()
                if now - last_press >= RESET_BUTTON_DEBOUNCE_SECONDS:
                    last_press = now
                    log("Reset button pressed")
                    reset_console()
        finally:
            if line is not None:
                line.release()
            if request is not None:
                request.release()
            if chip is not None:
                chip.close()

    thread = threading.Thread(target=listen, name="reset-button", daemon=True)
    thread.start()
    return stop_event, thread
