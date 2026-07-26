/**
 * Quality tier utilities shared by playlist import and legacy source migration.
 *
 * qualityScore ranks quality tiers best → worst. bestQuality() returns the
 * index of the best tier present in the song's `types` array (or
 * qualityScore.length if none match), so callers can sort by ascending
 * index to get best-first ordering.
 */
export const qualityScore = ['flac24bit', 'flac', '320k', '128k'];

export function bestQuality(types: string[] = []): number {
  for (let i = 0; i < qualityScore.length; i++) {
    if (types.includes(qualityScore[i])) return i;
  }
  return qualityScore.length;
}
