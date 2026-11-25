import type React from 'react';
import { Github } from 'lucide-react';
import { useAuth } from '../../hooks';
import { useUiLanguage } from '../../contexts/UiLanguageContext';
import { SettingsAlert } from './SettingsAlert';
import { SettingsSectionCard } from './SettingsSectionCard';

export const AuthSettingsCard: React.FC = () => {
  const { authEnabled, oauthConfigured, user } = useAuth();
  const { t } = useUiLanguage();
  return (
    <SettingsSectionCard title={t('login.githubTitle')} description={t('settings.githubAuthDescription')}>
      <div className="flex items-center gap-3">
        {user?.avatarUrl ? (
          <img src={user.avatarUrl} alt={user.name || user.login} width={48} height={48}
            className="h-12 w-12 rounded-full" referrerPolicy="no-referrer" />
        ) : <Github className="h-9 w-9 text-muted-text" aria-hidden="true" />}
        <div className="min-w-0">
          <p className="truncate font-medium text-foreground">{user ? user.login : t('login.githubTitle')}</p>
          {user?.email ? <p className="truncate text-sm text-muted-text">{user.email}</p> : null}
        </div>
      </div>
      <p className="text-sm leading-6 text-muted-text">{t('settings.githubAuthManaged')}</p>
      {!authEnabled || !oauthConfigured ? (
        <SettingsAlert title={t('login.githubTitle')} message={t('login.githubNotConfigured')} variant="warning" />
      ) : null}
    </SettingsSectionCard>
  );
};
