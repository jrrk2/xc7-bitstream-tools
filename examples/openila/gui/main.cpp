#include "mainwindow.h"
#include <QApplication>

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("openXC7");
    QCoreApplication::setApplicationName("openila-gui");
    MainWindow w;
    if (argc > 1) w.openMap(QString::fromLocal8Bit(argv[1]));   // openila-gui design.json.map
    w.show();
    return app.exec();
}
