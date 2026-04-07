import type { CcThemeId } from './lib/ccTheme';
import type { MessagePayload, PrependOlderOpts, ReplaceTimelineOpts } from './types';

export {};

declare global {
  interface Window {
    __FOLLOW_BOTTOM_THRESHOLD__?: number;
    __CCREADER_I18N__?: { copy: string; copied: string; emptyTitle: string; emptyHint: string };
    webkit?: {
      messageHandlers: {
        ccreader: { postMessage: (msg: Record<string, unknown>) => void };
      };
    };
    ccreader: {
      scrollBottomStable?: () => void;
      replaceTimelineFromPayloads?: (opts: ReplaceTimelineOpts) => void;
      replaceTimelineFromPayloadsProgressive?: (opts: ReplaceTimelineOpts) => void;
      prependOlderFromPayloads?: (opts: PrependOlderOpts) => void;
      appendMessagesFromPayload?: (payloads: MessagePayload[]) => void;
      replaceMessagesFromPayload?: (payloads: MessagePayload[]) => void;
      setWaitingIndicator?: (htmlOrEmpty: string) => void;
      setLoadOlderBar?: (htmlOrEmpty: string) => void;
      getTheme?: () => CcThemeId;
      setTheme?: (id: string) => void;
      cycleTheme?: () => CcThemeId;
      listThemes?: () => readonly CcThemeId[];
    };
  }
}
