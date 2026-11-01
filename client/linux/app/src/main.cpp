// Oshinobu для Linux: Qt Quick поверх ядра (core/). AppModel — синглтон App в QML.

#include "AppModel.h"
#include "Desktop.h"
#include "VideoView.h"
#ifdef OSHINOBU_HAVE_RLOTTIE
#include "TgsItem.h"
#endif
#include "support/Log.h"

#include <QApplication>
#include <QElapsedTimer>
#include <QFont>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>

int main(int argc, char **argv) {
    QApplication::setOrganizationName("Oshinobu");
    QApplication::setApplicationName("Oshinobu");
    QApplication::setDesktopFileName("space.oshino.Oshinobu");
    QApplication app(argc, argv);
    // цветные эмодзи раньше системного запасного шрифта: иначе fontconfig берёт чёрно-белые из DejaVu
    QFont font = QApplication::font();
    font.setFamilies({QStringLiteral("Inter"), QStringLiteral("Noto Sans"), QStringLiteral("Ubuntu"), QStringLiteral("Noto Color Emoji")});
    QApplication::setFont(font);
    QElapsedTimer startup;
    startup.start();
    // уже запущено — показать то окно (и открыть чат из --chat) и выйти
    SingleInstance instance;
    if (!instance.claim(app.arguments().mid(1))) return 0;
    app.setWindowIcon(QIcon(":/qt/qml/Oshinobu/icons/oshinobu.png"));
    // закрытие окна — в трей, приложение продолжает принимать сообщения
    app.setQuitOnLastWindowClosed(false);
    QQuickStyle::setStyle("Basic");

    AppModel model;
    const qint64 modelMs = startup.elapsed();
    qmlRegisterSingletonInstance("Oshinobu.Core", 1, 0, "App", &model);
    qmlRegisterType<VideoView>("Oshinobu.Core", 1, 0, "VideoView");
#ifdef OSHINOBU_HAVE_RLOTTIE
    qmlRegisterType<TgsItem>("Oshinobu.Core", 1, 0, "TgsSticker");
#endif

    QQmlApplicationEngine engine;
    engine.load(QUrl("qrc:/qt/qml/Oshinobu/Main.qml"));
    if (engine.rootObjects().isEmpty()) return 1;
    osh::log(QStringLiteral("Oshinobu %1 started (model %2 ms, ui %3 ms)").arg(QStringLiteral(OSHINOBU_VERSION)).arg(modelMs).arg(startup.elapsed() - modelMs));
    QObject::connect(&instance, &SingleInstance::activationRequested, &model, [&model](const QStringList &args) {
        Q_EMIT model.raiseRequested();
        if (const int i = args.indexOf("--chat"); i >= 0 && i + 1 < args.size()) model.openChatWith(args.at(i + 1));
    });
    model.launch();
    // --chat <логин> — открыть переписку сразу после входа
    if (const int i = app.arguments().indexOf("--chat"); i > 0 && i + 1 < app.arguments().size()) {
        const QString login = app.arguments().at(i + 1);
        QObject::connect(&model, &AppModel::phaseChanged, &model, [&model, login] {
            if (model.phase() == "signedIn") model.openChatWith(login);
        });
    }
    return app.exec();
}
