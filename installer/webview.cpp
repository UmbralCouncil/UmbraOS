#include <QApplication>
#include <QIcon>
#include <QUrl>
#include <QWebEngineDownloadRequest>
#include <QWebEnginePage>
#include <QWebEngineProfile>
#include <QWebEngineSettings>
#include <QWebEngineUrlRequestInfo>
#include <QWebEngineUrlRequestInterceptor>
#include <QWebEngineView>

namespace {

constexpr auto kInstallerHost = "127.0.0.1";
constexpr int kInstallerPort = 43110;

bool isInstallerUrl(const QUrl &url) {
  return url.scheme() == QStringLiteral("http") &&
         url.host() == QString::fromLatin1(kInstallerHost) &&
         url.port() == kInstallerPort;
}

class LocalOnlyInterceptor final : public QWebEngineUrlRequestInterceptor {
 public:
  using QWebEngineUrlRequestInterceptor::QWebEngineUrlRequestInterceptor;

  void interceptRequest(QWebEngineUrlRequestInfo &request) override {
    const QUrl url = request.requestUrl();
    const bool internal =
        url.scheme() == QStringLiteral("about") ||
        url.scheme() == QStringLiteral("data") ||
        url.scheme() == QStringLiteral("blob");
    if (!internal && !isInstallerUrl(url)) {
      request.block(true);
    }
  }
};

class LocalOnlyPage final : public QWebEnginePage {
 public:
  explicit LocalOnlyPage(QWebEngineProfile *profile, QObject *parent = nullptr)
      : QWebEnginePage(profile, parent) {}

 protected:
  bool acceptNavigationRequest(const QUrl &url, NavigationType type,
                               bool isMainFrame) override {
    Q_UNUSED(type);
    return !isMainFrame || isInstallerUrl(url) ||
           url.scheme() == QStringLiteral("about");
  }
};

class InstallerView final : public QWebEngineView {
 public:
  using QWebEngineView::QWebEngineView;

 protected:
  QWebEngineView *createWindow(QWebEnginePage::WebWindowType type) override {
    Q_UNUSED(type);
    return nullptr;
  }
};

}  // namespace

int main(int argc, char **argv) {
  QApplication application(argc, argv);
  application.setApplicationName(QStringLiteral("Umbra Installer"));
  application.setOrganizationName(QStringLiteral("Umbra Project"));

  if (argc < 2) {
    qCritical("usage: umbra-installer-webview URL [ICON]");
    return 2;
  }

  const QUrl installerUrl = QUrl::fromUserInput(QString::fromLocal8Bit(argv[1]));
  if (!isInstallerUrl(installerUrl)) {
    qCritical("refusing to load a URL outside the local installer origin");
    return 2;
  }

  auto *profile = new QWebEngineProfile(&application);
  profile->setHttpCacheType(QWebEngineProfile::MemoryHttpCache);
  profile->setPersistentCookiesPolicy(
      QWebEngineProfile::NoPersistentCookies);
  profile->setHttpCacheMaximumSize(0);

  auto *interceptor = new LocalOnlyInterceptor(profile);
  profile->setUrlRequestInterceptor(interceptor);
  QObject::connect(
      profile, &QWebEngineProfile::downloadRequested,
      [](QWebEngineDownloadRequest *download) { download->cancel(); });

  InstallerView view;
  auto *page = new LocalOnlyPage(profile, &view);
  view.setPage(page);
  view.setWindowTitle(QStringLiteral("Install UmbraOS"));
  if (argc >= 3) {
    view.setWindowIcon(QIcon(QString::fromLocal8Bit(argv[2])));
  }
  view.setContextMenuPolicy(Qt::NoContextMenu);
  view.setMinimumSize(800, 560);
  view.resize(920, 680);

  QWebEngineSettings *settings = view.settings();
  settings->setAttribute(QWebEngineSettings::JavascriptCanOpenWindows, false);
  settings->setAttribute(QWebEngineSettings::JavascriptCanAccessClipboard,
                         false);
  settings->setAttribute(QWebEngineSettings::LocalContentCanAccessRemoteUrls,
                         false);
  settings->setAttribute(QWebEngineSettings::LocalContentCanAccessFileUrls,
                         false);
  settings->setAttribute(QWebEngineSettings::PluginsEnabled, false);
  settings->setAttribute(QWebEngineSettings::FullScreenSupportEnabled, false);

  view.load(installerUrl);
  view.show();
  return application.exec();
}
