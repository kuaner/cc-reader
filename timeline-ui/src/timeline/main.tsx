import { installCcreader } from '../bridge/installCcreader';
import { injectHljsThemes } from '../hljsThemes';
import { enhanceSubtree } from '../markdown/markdown';
import '../styles/tailwind.css';
import '../styles/web-chrome.css';

injectHljsThemes();

installCcreader();

enhanceSubtree(document);
window.scrollTo(0, document.body.scrollHeight);
