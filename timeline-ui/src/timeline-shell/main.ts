import { installCcreader } from './bridge/installCcreader';
import '../styles/timeline-app.css';
import '../styles/markdown-shared.css';
import '../styles/timeline.css';

installCcreader();
window.scrollTo(0, document.body.scrollHeight);

