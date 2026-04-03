import { installCcreader } from '../bridge/installCcreader';
import { enhanceSubtree } from '../markdown/markdown';
import '../styles/timeline-app.css';
import '../styles/markdown-shared.css';
import '../styles/timeline.css';

installCcreader();

enhanceSubtree(document);
window.scrollTo(0, document.body.scrollHeight);
