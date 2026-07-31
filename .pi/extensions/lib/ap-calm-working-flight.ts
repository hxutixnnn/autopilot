// Autopilot's Calm-only animated working presentation.
//
// Calm replaces Pi's stock working row with a tiny animated airplane while one
// logical agent run is active. This module owns only the sprite geometry, the bounce
// track, the two animation cadences, the session-scoped freeze/resume state, and the
// temporary TUI widget; `.pi/extensions/ap-calm.ts` owns when the presentation is
// installed and removed, and stays the sole caller of setWorkingVisible().
// docs/calm.md owns the pilot-facing contract.
//
// Cadence: one scheduler drives two logically independent clocks. Every tick advances
// the sky phase, and only every CALM_WORKING_FLIGHT_TICKS_PER_MOVE-th tick moves the
// airplane, so the sky visibly ripples several times between airplane steps and the airplane
// itself reads as calm. Both clocks stop together when the widget is disposed. Ticks,
// not wall-clock timestamps, drive every state change, so tests can seek time exactly.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes column,
// direction, sky phase, and tick cadence without advancing them for hidden wall
// time. The next working period resumes from that exact logical state. A fresh session
// or new extension lifetime calls reset() and starts at the normal initial position.
// State is never a module-level or process-global singleton.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate. A resize while the airplane is hidden is
// applied on the first resumed frame through the same clamp path.
import type { Component, TUI } from "@earendil-works/pi-tui";

// The fuselage replaces sky cells on its row rather than adding a third row.
const FUSELAGE = "-o-";
// A directional nose marker sits above the center of the three-cell fuselage.
const WING_RIGHT = ">";
const WING_LEFT = "<";
const WING_OFFSET = 1;
const FUSELAGE_WIDTH = FUSELAGE.length;
const WING_WIDTH = WING_RIGHT.length;

// Bounded deterministic fixed-cell sky phases. Every entry is exactly one column, so
// advancing the phase ripples the surface without changing visible width or row count.
const SKY_CYCLE = [".", " ", "·", " "] as const;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const YELLOW = "\u001b[33m";
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

export const CALM_WORKING_FLIGHT_WIDGET_KEY = "autopilot-calm-working-flight";
/** Scheduler period. One tick advances the sky by one phase. */
export const CALM_WORKING_FLIGHT_TICK_MS = 220;
/** Airplane moves one column every Nth tick, so it travels at 220 * 4 = 880ms per column. */
export const CALM_WORKING_FLIGHT_TICKS_PER_MOVE = 4;

export type CalmWorkingFlightAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one scheduler tick: sky every tick, airplane on its slower cadence. */
  tick(): void;
  restoreLastRendered(): void;
  /** Restore the normal initial column, direction, sky phase, and cadence. */
  reset(): void;
  /**
   * Clamp the frozen column and direction to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current fuselage column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel direction: 1 travelling right, -1 travelling left. */
  direction(): number;
  /** Current sky phase, exposed for deterministic ripple assertions. */
  skyPhase(): number;
};

/** Longest fuselage start column that still fits the sprite in `width` usable cells. */
function trackSpan(width: number): number {
  if (width >= FUSELAGE_WIDTH) return width - FUSELAGE_WIDTH;
  if (width >= WING_WIDTH) return width - WING_WIDTH;
  return 0;
}

export function createCalmWorkingFlightAnimation(): CalmWorkingFlightAnimation {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;

  // Reversing the moment the airplane lands on an endpoint means the endpoint frame itself
  // already shows the new heading, so no frame at or after a bounce shows the old wing.
  const settleDirectionAtEdges = (): void => {
    if (span <= 0) return;
    if (position >= span) direction = -1;
    else if (position <= 0) direction = 1;
  };

  const applyWidth = (width: number): void => {
    if (width <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(width);
    position = Math.min(position, span);
    settleDirectionAtEdges();
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedDirection = direction;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    direction = renderedDirection;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
  };

  /** One colored run of sky covering absolute columns [from, from + count). */
  const sky = (from: number, count: number): string => {
    if (count <= 0) return "";
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += SKY_CYCLE[(column + phase) % SKY_CYCLE.length];
    }
    return `${BLUE}${cells}${RESET}`;
  };

  const airplane = (text: string): string => `${YELLOW}${text}${RESET}`;

  return {
    position: () => position,
    direction: () => direction,
    skyPhase: () => phase,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      direction = 1;
      span = 0;
      phase = 0;
      ticks = 0;
      commitRenderedState();
    },

    clampToWidth(width: number): void {
      applyWidth(width);
    },

    tick(): void {
      ticks += 1;
      phase = (phase + 1) % SKY_CYCLE.length;
      if (ticks % CALM_WORKING_FLIGHT_TICKS_PER_MOVE !== 0) return;
      if (span <= 0) {
        position = 0;
        return;
      }
      position = Math.min(span, Math.max(0, position + direction));
      settleDirectionAtEdges();
    },

    render(width: number): string[] {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);

      const wing = direction >= 0 ? WING_RIGHT : WING_LEFT;

      let frame: string[];
      if (width < WING_WIDTH) {
        // Too narrow for even the wing: a deterministic single row of sky.
        frame = [sky(0, width)];
      } else if (width < FUSELAGE_WIDTH) {
        // Too narrow for the fuselage: the wing alone rides the sky row.
        frame = [
          sky(0, position) +
            airplane(wing) +
            sky(position + WING_WIDTH, width - position - WING_WIDTH),
        ];
      } else {
        frame = [
          " ".repeat(position + WING_OFFSET) + airplane(wing),
          sky(0, position) +
            airplane(FUSELAGE) +
            sky(position + FUSELAGE_WIDTH, width - position - FUSELAGE_WIDTH),
        ];
      }

      commitRenderedState();
      return frame;
    },
  };
}

/**
 * Build the temporary Calm working widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler driving both
 * cadences cannot outlive the widget or duplicate. Disposing freezes the shared
 * animation in place; the next widget bound to the same animation resumes without
 * applying hidden wall time.
 */
export function createCalmWorkingFlightWidget(
  tui: TUI,
  animation: CalmWorkingFlightAnimation = createCalmWorkingFlightAnimation(),
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_FLIGHT_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (width) => (disposed ? [] : animation.render(width)),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}
