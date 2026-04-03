export interface ToolPayload {
  title?: string;
  body?: string;
  renderStyle?: string;
}

export interface ResultImageItem {
  mediaType?: string;
  base64?: string;
}

export interface MessagePayload {
  uuid: string;
  domId: string;
  isUser?: boolean;
  isCompactSummary?: boolean;
  isApiError?: boolean;
  isSummary?: boolean;
  timeLabel?: string;
  content?: string;
  thinking?: string;
  thinkingTitle?: string;
  modelTitle?: string;
  assistantLabel?: string;
  contextLabel?: string;
  legendLabel?: string;
  legendUser?: string;
  legendAssistant?: string;
  legendSummary?: string;
  summaryLabel?: string;
  bubbleKind?: string;
  specialTag?: string;
  inputTokens?: number;
  cacheReadTokens?: number;
  outputTokens?: number;
  rawData?: string;
  rawDataLabel?: string;
  metaTags?: string[];
  renderMode?: string;
  resultImages?: ResultImageItem[];
  tools?: ToolPayload[];
}

export interface ReplaceTimelineOpts {
  messages?: MessagePayload[];
  loadOlderBarHTML?: string;
  waitingHTML?: string;
  initialLatestCount?: number;
  prependChunkSize?: number;
}

export interface PrependOlderOpts {
  messages?: MessagePayload[];
  removeOlderBar?: boolean;
}

export interface TimelineState {
  messages: MessagePayload[];
  loadOlderHTML: string;
  waitingHTML: string;
}
