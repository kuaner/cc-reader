import { installCcreader } from '../bridge/installCcreader';
import { enhanceSubtree } from '../markdown/markdown';
import '../styles/tailwind.css';
import '../styles/web-chrome.css';
import '../styles/hljs-runtime-themes.css';

installCcreader();

enhanceSubtree(document);
window.scrollTo(0, document.body.scrollHeight);
