import type React from 'react';
import { useEffect } from 'react';
import { Github, ShieldCheck } from 'lucide-react';
import { useSearchParams } from 'react-router-dom';
import { Button, ParticleBackground } from '../components/common';
import { UiLanguageToggle } from '../components/i18n/UiLanguageToggle';
import { SettingsAlert } from '../components/settings/SettingsAlert';
import { useAuth } from '../hooks';
import { useUiLanguage } from '../contexts/UiLanguageContext';
import { getDesktopRuntimeApi } from '../desktop/runtime';
import type { UiTextKey } from '../i18n/uiText';
import { API_BASE_URL } from '../utils/constants';
import { resolveLoginRedirect } from '../utils/loginRedirect';

const oauthErrors: Record<string, UiTextKey> = {
  denied: 'login.githubDenied',
  not_allowed: 'login.githubNotAllowed',
  email_required: 'login.githubEmailRequired',
  invalid_state: 'login.githubInvalidState',
  rate_limited: 'login.githubRateLimited',
  not_configured: 'login.githubNotConfigured',
  session_unavailable: 'login.githubUnavailable',
  unavailable: 'login.githubUnavailable',
  authorization_failed: 'login.githubDenied',
};

const LoginPage: React.FC = () => {
  const { oauthConfigured } = useAuth();
  const { t } = useUiLanguage();
  const [searchParams] = useSearchParams();
  const redirect = resolveLoginRedirect(searchParams.get('redirect'));
  const error = searchParams.get('oauthError');
  const desktop = Boolean(getDesktopRuntimeApi());

  useEffect(() => { document.title = t('login.pageTitle'); }, [t]);

  const startLogin = () => {
    const url = new URL(API_BASE_URL.replace(/\/$/, '') + '/api/v1/auth/github/login', window.location.origin);
    url.searchParams.set('redirect', redirect);
    if (desktop) {
      // Electron opens this in the system browser; GitHub never receives the desktop preload bridge.
      window.open(url.toString(), '_blank', 'noopener,noreferrer');
    } else {
      window.location.assign(url.toString());
    }
  };

  return (
    <div className="relative flex min-h-screen items-center justify-center overflow-hidden bg-[var(--login-bg-main)] px-4 py-12">
      <ParticleBackground />
      <div className="absolute right-4 top-4 z-30"><UiLanguageToggle /></div>
      <div className="relative z-10 w-full max-w-md space-y-8">
        <div className="text-center">
          <h1 className="text-3xl font-bold tracking-tight text-[var(--login-text-primary)]">DAILY STOCK</h1>
          <p className="mt-2 text-sm text-[var(--login-text-muted)]">Analysis Engine</p>
        </div>
        <section className="space-y-6 rounded-3xl border border-[var(--login-border-card)] bg-[var(--login-bg-card)] p-8 shadow-2xl">
          <div className="space-y-3">
            <Github className="h-9 w-9 text-[var(--login-text-primary)]" aria-hidden="true" />
            <h2 className="text-2xl font-bold text-[var(--login-text-primary)]">{t('login.githubTitle')}</h2>
            <p className="text-sm leading-6 text-[var(--login-text-secondary)]">{t('login.githubDescription')}</p>
          </div>
          {!oauthConfigured ? (
            <SettingsAlert title={t('login.githubTitle')} message={t('login.githubNotConfigured')} variant="warning" />
          ) : null}
          {error ? (
            <SettingsAlert title={t('login.loginFailed')}
              message={t(oauthErrors[error] ?? 'login.githubUnavailable')} variant="error" />
          ) : null}
          {desktop ? <p className="text-sm text-[var(--login-text-secondary)]">{t('login.githubDesktop')}</p> : null}
          <Button type="button" variant="primary" size="lg" className="w-full" disabled={!oauthConfigured} onClick={startLogin}>
            <Github className="mr-2 h-5 w-5" aria-hidden="true" />
            {t('login.githubSubmit')}
          </Button>
          <p className="flex gap-2 text-xs leading-5 text-[var(--login-text-muted)]">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            {t('login.githubPermissions')}
          </p>
        </section>
      </div>
    </div>
  );
};

export default LoginPage;
