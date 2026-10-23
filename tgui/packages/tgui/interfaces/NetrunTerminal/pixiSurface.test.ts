import { PIXI_LIMITS, pixiWithinBudget } from './pixiSurface';

describe('NetRun Pixi GPU allocation guards', () => {
  test('accepts a normal map while rejecting oversized topology', () => {
    expect(pixiWithinBudget(500, 900, 1280, 800)).toBe(true);
    expect(pixiWithinBudget(PIXI_LIMITS.maxNodes + 1, 0, 1280, 800)).toBe(false);
    expect(pixiWithinBudget(100, PIXI_LIMITS.maxEdges + 1, 1280, 800)).toBe(false);
    expect(pixiWithinBudget(1, 1, 1280, 800, PIXI_LIMITS.maxZoneRuns + 1)).toBe(false);
  });

  test('prevents oversize framebuffers and invalid viewport sizes', () => {
    expect(pixiWithinBudget(1, 1, 3000, 2000)).toBe(false);
    expect(pixiWithinBudget(1, 1, 0, 800)).toBe(false);
  });
});
