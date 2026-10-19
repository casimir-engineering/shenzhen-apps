// The link pages' settings (README.md § Configuration): where the friend and download pages send someone who has
// none of the apps yet. Each is an https URL; anything else stops the service at start with the variable's name.

const DEFAULT_PDF_URL = 'https://casimir-engineering.github.io/shenzhen-pdf/';
const DEFAULT_FILES_URL = 'https://github.com/casimir-engineering/shenzhen-files/releases/latest';

function httpsUrl(env, name, fallback) {
    const raw = env[name];
    if (raw === undefined || raw === '') return fallback;
    let url;
    try {
        url = new URL(raw);
    } catch {
        url = null;
    }
    if (!url || url.protocol !== 'https:' || raw.length > 300 || url.username || url.password) {
        throw new Error(`${name} must be an https URL of at most 300 characters`);
    }
    return url.href;
}

export function linksConfig(env) {
    return {
        pdfUrl: httpsUrl(env, 'FRIENDS_LINKS_PDF_URL', DEFAULT_PDF_URL),
        filesUrl: httpsUrl(env, 'FRIENDS_LINKS_FILES_URL', DEFAULT_FILES_URL),
        // Shenzhen 3D has no public download yet, so with no setting the pages offer no "Get" link for it.
        threeDUrl: httpsUrl(env, 'FRIENDS_LINKS_3D_URL', ''),
    };
}
