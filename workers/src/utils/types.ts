/** Shared type definitions for lx-music-api */

export interface SongInfo {
  name: string;
  singer: string;
  source: string;
  songmid: string;
  albumName?: string;
  albumId?: string;
  img?: string;
  interval?: string;
  types?: string[];
  hash?: string;
  mrcUrl?: string;
  lrcUrl?: string;
  trcUrl?: string;
}

export interface PlaylistImportResult {
  name: string;
  songs: SongInfo[];
}

// Request body types
export interface PlaylistImportSaveBody {
  name: string;
  source?: string;
  sourceId?: string;
  songs: SongInfo[];
}
