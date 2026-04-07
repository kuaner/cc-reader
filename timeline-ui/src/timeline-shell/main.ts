import { initCcTheme } from '../lib/ccTheme';
import { installCcreader } from './bridge/installCcreader';
import '../styles/timeline-app.css';
import '../styles/markdown-shared.css';
import '../styles/timeline.css';

initCcTheme();
installCcreader();
window.scrollTo(0, document.body.scrollHeight);

