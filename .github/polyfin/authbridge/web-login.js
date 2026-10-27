// Injected into Polyfin's already existing /web/polyfin.js.
// This adds presentation only: the identity check and Jellyfin session
// issuance always happen on the Polyfin backend.
;(() => {
  const id = 'polyfin-authentik-login';
  function show() {
    // jellyfin-web is a SPA. Restrict the button to a password login form,
    // not arbitrary password fields on settings/account pages.
    if (!/^#\/(?:login|signin)(?:\?|\/|$)/i.test(location.hash)) return;
    const form = [...document.querySelectorAll('form')].find(
      (f) => f.querySelector('input[type="password"]')
    );
    if (!form || document.getElementById(id)) return;
    const link = document.createElement('a');
    link.id = id;
    link.href = '/polyfin-sso/complete';
    link.textContent = 'Se connecter avec Authentik';
    link.setAttribute('aria-label', 'Se connecter avec Authentik');
    link.style.cssText = 'display:block;text-align:center;padding:12px 16px;margin:16px auto;border:1px solid currentColor;border-radius:12px;max-width:400px;text-decoration:none';
    form.insertAdjacentElement('afterend', link);
  }
  document.addEventListener('DOMContentLoaded', show);
  window.addEventListener('hashchange', show);
  const observer = new MutationObserver(show);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  show();
})();
