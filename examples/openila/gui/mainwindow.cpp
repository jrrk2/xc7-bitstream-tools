#include "mainwindow.h"
#include <QAction>
#include <cstdio>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QMenuBar>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QScrollArea>
#include <QSettings>
#include <QSpinBox>
#include <QStatusBar>
#include <QTableWidget>
#include <QTextStream>
#include <QTimer>
#include <QToolBar>
#include <QVBoxLayout>

MainWindow::MainWindow()
{
    setWindowTitle("openila");
    resize(1300, 760);
    QSettings st("openXC7", "openila-gui");

    // ---- centre: the waveform, scrollable vertically ----
    wave_ = new Waveform;
    auto *scroll = new QScrollArea;
    scroll->setWidget(wave_);
    scroll->setWidgetResizable(true);
    scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    setCentralWidget(scroll);

    // ---- left dock: connection and instance settings ----
    auto *setDock = new QDockWidget("ILA", this);
    setDock->setFeatures(QDockWidget::DockWidgetMovable);
    auto *setW = new QWidget;
    auto *form = new QFormLayout(setW);
    oflEdit_ = new QLineEdit(st.value("ofl", ila_.cfg.ofl).toString());
    cableEdit_ = new QLineEdit(st.value("cable", "digilent").toString());
    freqSpin_ = new QSpinBox; freqSpin_->setRange(100000, 30000000); freqSpin_->setSingleStep(1000000); freqSpin_->setValue(st.value("freq", 15000000).toInt());
    widthSpin_ = new QSpinBox; widthSpin_->setRange(16, 4096); widthSpin_->setValue(st.value("width", 64).toInt());
    depthSpin_ = new QSpinBox; depthSpin_->setRange(16, 1 << 20); depthSpin_->setValue(st.value("depth", 1024).toInt());
    ctlSpin_ = new QSpinBox; ctlSpin_->setRange(1, 4); ctlSpin_->setValue(st.value("ctl", 2).toInt());
    datSpin_ = new QSpinBox; datSpin_->setRange(1, 4); datSpin_->setValue(st.value("dat", 3).toInt());
    clkSpin_ = new QDoubleSpinBox; clkSpin_->setRange(0.1, 10000); clkSpin_->setDecimals(3); clkSpin_->setValue(st.value("clkns", 8.0).toDouble());
    mapEdit_ = new QLineEdit(st.value("map").toString());
    auto *mapBtn = new QPushButton("...");
    auto *mapRow = new QHBoxLayout; mapRow->addWidget(mapEdit_); mapRow->addWidget(mapBtn);
    form->addRow("openFPGALoader", oflEdit_);
    form->addRow("cable", cableEdit_);
    form->addRow("TCK (Hz)", freqSpin_);
    form->addRow("WIDTH", widthSpin_);
    form->addRow("DEPTH", depthSpin_);
    form->addRow("control USER", ctlSpin_);
    form->addRow("data USER", datSpin_);
    form->addRow("clock (ns)", clkSpin_);
    form->addRow("probe map", mapRow);
    setDock->setWidget(setW);
    addDockWidget(Qt::LeftDockWidgetArea, setDock);

    // ---- left dock: trigger ----
    auto *trigDock = new QDockWidget("Trigger", this);
    trigDock->setFeatures(QDockWidget::DockWidgetMovable);
    auto *trigW = new QWidget;
    auto *tv = new QVBoxLayout(trigW);
    trig_ = new QTableWidget(0, 3);
    trig_->setHorizontalHeaderLabels({"signal", "bits", "condition"});
    trig_->horizontalHeader()->setStretchLastSection(true);
    trig_->verticalHeader()->setVisible(false);
    trig_->setEditTriggers(QAbstractItemView::AllEditTriggers);
    tv->addWidget(new QLabel("condition: x = don't care, 0/1, or a hex value for a bus"));
    tv->addWidget(trig_);
    auto *postRow = new QHBoxLayout;
    postSpin_ = new QSpinBox; postSpin_->setRange(0, 1 << 20); postSpin_->setValue(st.value("post", 512).toInt());
    postRow->addWidget(new QLabel("samples after the trigger")); postRow->addWidget(postSpin_);
    tv->addLayout(postRow);
    auto *btnRow = new QHBoxLayout;
    armBtn_ = new QPushButton("Arm"); disarmBtn_ = new QPushButton("Disarm");
    statusBtn_ = new QPushButton("Status"); readBtn_ = new QPushButton("Read");
    for (auto *b : {armBtn_, disarmBtn_, statusBtn_, readBtn_}) btnRow->addWidget(b);
    tv->addLayout(btnRow);
    pollChk_ = new QCheckBox("poll status while armed, read when done");
    pollChk_->setChecked(st.value("poll", true).toBool());
    tv->addWidget(pollChk_);
    statusLbl_ = new QLabel("-");
    statusLbl_->setWordWrap(true);
    tv->addWidget(statusLbl_);
    trigDock->setWidget(trigW);
    addDockWidget(Qt::LeftDockWidgetArea, trigDock);

    // ---- bottom dock: log ----
    auto *logDock = new QDockWidget("Log", this);
    logDock->setFeatures(QDockWidget::DockWidgetMovable | QDockWidget::DockWidgetClosable);
    log_ = new QPlainTextEdit; log_->setReadOnly(true); log_->setMaximumBlockCount(500);
    log_->setFont(QFont("monospace", 8));
    logDock->setWidget(log_);
    addDockWidget(Qt::BottomDockWidgetArea, logDock);

    // ---- menu ----
    auto *file = menuBar()->addMenu("&File");
    file->addAction("Load probe map...", [this] {
        QString p = QFileDialog::getOpenFileName(this, "probe map", mapEdit_->text(), "map (*.map);;all (*)");
        if (!p.isEmpty()) { mapEdit_->setText(p); loadMap(p); }
    });
    file->addAction("Load capture...", this, &MainWindow::loadCapture);
    file->addAction("Save capture...", this, &MainWindow::saveCapture);
    file->addAction("Export VCD...", this, &MainWindow::exportVcd);
    file->addSeparator();
    file->addAction("Quit", this, &QWidget::close);
    auto *view = menuBar()->addMenu("&View");
    view->addAction("Zoom to fit (F)", [this] { wave_->zoomFit(); });
    view->addAction("Go to trigger (T)", [this] { wave_->setCursor(depthSpin_->value() - 1 - lastPost_); });
    auto *help = menuBar()->addMenu("&Help");
    help->addAction("About", [this] {
        QMessageBox::about(this, "openila",
                           "A logic analyser for a Xilinx 7-series design, read over JTAG with openFPGALoader.\n\n"
                           "examples/openila in xc7-bitstream-tools: splice openila.v into a netlist with "
                           "openila_merge.py, load its .map here, arm, run the design, read.\n\n"
                           "Waveform: wheel zooms, drag pans, click sets the cursor; arrows step, T = trigger, F = fit.");
    });

    // ---- wiring ----
    connect(mapBtn, &QPushButton::clicked, [this] {
        QString p = QFileDialog::getOpenFileName(this, "probe map", mapEdit_->text(), "map (*.map);;all (*)");
        if (!p.isEmpty()) { mapEdit_->setText(p); loadMap(p); }
    });
    connect(mapEdit_, &QLineEdit::editingFinished, [this] { loadMap(mapEdit_->text()); });
    connect(widthSpin_, QOverload<int>::of(&QSpinBox::valueChanged), [this](int) { rebuildTriggerTable(); });
    connect(armBtn_, &QPushButton::clicked, this, &MainWindow::doArm);
    connect(disarmBtn_, &QPushButton::clicked, [this] { applyConfig(); poll_->stop(); ila_.disarm(); });
    connect(statusBtn_, &QPushButton::clicked, [this] { applyConfig(); ila_.status(); });
    connect(readBtn_, &QPushButton::clicked, [this] { applyConfig(); ila_.read(); });
    connect(&ila_, &Ila::statusReady, this, &MainWindow::onStatus);
    connect(&ila_, &Ila::captureReady, this, &MainWindow::onCapture);
    connect(&ila_, &Ila::error, this, &MainWindow::onError);
    connect(&ila_, &Ila::busyChanged, this, &MainWindow::setBusy);
    connect(&ila_, &Ila::log, [this](const QString &l) {
        log_->appendPlainText(l);
        if (!qgetenv("OPENILA_AUTOTEST").isEmpty()) { fprintf(stderr, "%s\n", qPrintable(l)); fflush(stderr); }
    });
    connect(wave_, &Waveform::cursorMoved, [this](int t) {
        statusBar()->showMessage(QString("cursor: sample %1, %2 ns").arg(t).arg(t * clkSpin_->value(), 0, 'f', 1));
    });
    poll_ = new QTimer(this);
    poll_->setInterval(1000);
    connect(poll_, &QTimer::timeout, [this] {
        if (!ila_.busy()) ila_.status();
    });

    if (!mapEdit_->text().isEmpty()) loadMap(mapEdit_->text());
    else rebuildTriggerTable();
    statusBar()->showMessage("ready");

    // OPENILA_AUTOTEST=<vcd path>: arm, read, export, quit -- a smoke test
    // against a stand-in openFPGALoader, with no one at the mouse.
    QByteArray autotest = qgetenv("OPENILA_AUTOTEST");
    if (!autotest.isEmpty()) {
        QTimer::singleShot(300, this, [this] { doArm(); });
        QTimer::singleShot(20000, this, [] { fprintf(stderr, "autotest: no capture within 20 s\n"); qApp->exit(2); });
        connect(&ila_, &Ila::captureReady, this, [this, autotest](IlaStatus, QVector<Bits>) {
            QFile f(QString::fromLocal8Bit(autotest));
            if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
                QTextStream o(&f);
                for (int t = 0; t < qMin(8, samples_.size()); t++) {
                    o << t;
                    for (const auto &s : sigs_) o << " " << s.name << "=" << QString::number(wave_->valueAt(s, t), 16);
                    o << "\n";
                }
            }
            wave_->setCursor(20);
            grab().save(QString::fromLocal8Bit(autotest) + ".png");
            wave_->zoomTo(900, 24);
            wave_->setCursor(923);
            grab().save(QString::fromLocal8Bit(autotest) + ".zoom.png");
            fprintf(stderr, "autotest: capture of %d samples written\n", int(samples_.size())); fflush(stderr);
            QTimer::singleShot(200, qApp, &QApplication::quit);
        });
    }
}

void MainWindow::applyConfig()
{
    ila_.cfg.ofl = oflEdit_->text();
    ila_.cfg.cable = cableEdit_->text();
    ila_.cfg.freq = freqSpin_->value();
    ila_.cfg.width = widthSpin_->value();
    ila_.cfg.depth = depthSpin_->value();
    ila_.cfg.ctl = ctlSpin_->value();
    ila_.cfg.dat = datSpin_->value();
    ila_.cfg.clkNs = clkSpin_->value();
    QSettings st("openXC7", "openila-gui");
    st.setValue("ofl", ila_.cfg.ofl); st.setValue("cable", ila_.cfg.cable); st.setValue("freq", ila_.cfg.freq);
    st.setValue("width", ila_.cfg.width); st.setValue("depth", ila_.cfg.depth); st.setValue("ctl", ila_.cfg.ctl);
    st.setValue("dat", ila_.cfg.dat); st.setValue("clkns", ila_.cfg.clkNs); st.setValue("map", mapEdit_->text());
    st.setValue("post", postSpin_->value()); st.setValue("poll", pollChk_->isChecked());
}

// The map openila_merge.py writes: "<bit> <net name>" per line; consecutive
// bits of one bus (name[k]) become a bus row, LSB first.
void MainWindow::loadMap(const QString &path)
{
    QFile f(path);
    sigs_.clear();
    if (f.open(QIODevice::ReadOnly)) {
        QTextStream in(&f);
        QMap<int, QString> names;
        while (!in.atEnd()) {
            QString l = in.readLine().trimmed();
            if (l.isEmpty()) continue;
            QStringList p = l.split(' ');
            if (p.size() == 2) names[p[0].toInt()] = p[1];
        }
        for (auto it = names.begin(); it != names.end(); ++it) {
            QString n = it.value();
            QString bus = n.endsWith(']') ? n.left(n.lastIndexOf('[')) : n;
            if (!sigs_.isEmpty() && sigs_.last().name == bus) sigs_.last().bits.append(it.key());
            else sigs_.append({bus, {it.key()}});
        }
        log_->appendPlainText(QString("map %1: %2 signals").arg(path).arg(sigs_.size()));
    } else if (!path.isEmpty()) {
        log_->appendPlainText("cannot read map " + path);
    }
    rebuildTriggerTable();
}

void MainWindow::rebuildTriggerTable()
{
    if (sigs_.isEmpty())
        for (int k = 0; k < widthSpin_->value(); k++) sigs_.append({QString("p%1").arg(k), {k}});
    trig_->setRowCount(sigs_.size());
    for (int r = 0; r < sigs_.size(); r++) {
        auto *n = new QTableWidgetItem(sigs_[r].name); n->setFlags(n->flags() & ~Qt::ItemIsEditable);
        auto *w = new QTableWidgetItem(QString::number(sigs_[r].bits.size())); w->setFlags(w->flags() & ~Qt::ItemIsEditable);
        trig_->setItem(r, 0, n); trig_->setItem(r, 1, w);
        trig_->setItem(r, 2, new QTableWidgetItem("x"));
    }
    trig_->resizeColumnToContents(0);
    trig_->resizeColumnToContents(1);
    wave_->setSignals(sigs_);
}

bool MainWindow::triggerWord(Bits &mask, Bits &value, QString &err) const
{
    int W = widthSpin_->value();
    mask = Bits(W); value = Bits(W);
    for (int r = 0; r < sigs_.size(); r++) {
        QString c = trig_->item(r, 2) ? trig_->item(r, 2)->text().trimmed().toLower() : "x";
        if (c.isEmpty() || c == "x" || c == "-") continue;
        if (c.startsWith("0x")) c = c.mid(2);
        bool ok; quint64 v = c.toULongLong(&ok, 16);
        if (!ok) { err = QString("%1: '%2' is not x, 0/1 or a hex value").arg(sigs_[r].name, c); return false; }
        const auto &bits = sigs_[r].bits;
        if (bits.size() < 64 && v >> bits.size()) { err = QString("%1: %2 does not fit in %3 bits").arg(sigs_[r].name, c).arg(bits.size()); return false; }
        for (int i = 0; i < bits.size(); i++) { mask.set(bits[i], true); value.set(bits[i], (v >> i) & 1); }
    }
    return true;
}

void MainWindow::doArm()
{
    applyConfig();
    Bits mask, value; QString err;
    if (!triggerWord(mask, value, err)) { QMessageBox::warning(this, "trigger", err); return; }
    int post = qMin(postSpin_->value(), depthSpin_->value() - 1);
    lastPost_ = post;
    log_->appendPlainText(QString("arm: mask=%1 value=%2 post=%3").arg(mask.hex(), value.hex()).arg(post));
    ila_.arm(mask, value, post);
    if (pollChk_->isChecked()) poll_->start();
}

void MainWindow::onStatus(IlaStatus st)
{
    lastStatus_ = st;
    statusLbl_->setText(st.text());
    log_->appendPlainText("status: " + st.text());
    if (!st.keyOk) poll_->stop();
    // (the status a write scans out is the state before that write, so an
    // "idle" right after arming is expected and no reason to stop polling)
    if (poll_->isActive() && st.done) { poll_->stop(); ila_.read(); }   // read() queues behind the scan in flight
}

void MainWindow::onCapture(IlaStatus st, QVector<Bits> samples)
{
    lastStatus_ = st;
    samples_ = samples;
    statusLbl_->setText(st.text());
    int trigger = st.trig ? samples.size() - 1 - lastPost_ : -1;
    wave_->setCapture(samples_, trigger, clkSpin_->value());
    log_->appendPlainText(QString("read %1 samples; %2").arg(samples.size()).arg(st.text()));
    if (!st.done) statusBar()->showMessage("capture read while not done: the buffer is still being written", 5000);
}

void MainWindow::onError(const QString &what)
{
    poll_->stop();
    log_->appendPlainText("ERROR " + what);
    if (!qgetenv("OPENILA_AUTOTEST").isEmpty()) { fprintf(stderr, "ERROR %s\n", qPrintable(what)); fflush(stderr); qApp->exit(1); return; }
    QMessageBox::critical(this, "openila", what);
}

void MainWindow::setBusy(bool b)
{
    for (auto *w : {armBtn_, disarmBtn_, statusBtn_, readBtn_}) w->setEnabled(!b);
    statusBar()->showMessage(b ? "JTAG..." : "ready");
}

void MainWindow::exportVcd()
{
    if (samples_.isEmpty()) { QMessageBox::information(this, "VCD", "nothing captured yet"); return; }
    QString p = QFileDialog::getSaveFileName(this, "export VCD", "capture.vcd", "VCD (*.vcd)");
    if (p.isEmpty()) return;
    QFile f(p);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) { onError("cannot write " + p); return; }
    QTextStream o(&f);
    o << "$timescale 1ps $end\n$scope module ila $end\n";
    QVector<QString> ids;
    for (int j = 0; j < sigs_.size(); j++) {
        ids.append(j < 90 ? QString(QChar(33 + j)) : QString("v%1").arg(j));
        o << "$var wire " << sigs_[j].bits.size() << " " << ids[j] << " " << sigs_[j].name << " $end\n";
    }
    o << "$upscope $end\n$enddefinitions $end\n";
    QVector<qint64> last(sigs_.size(), -1);
    for (int t = 0; t < samples_.size(); t++) {
        o << "#" << qint64(t * clkSpin_->value() * 1000) << "\n";
        for (int j = 0; j < sigs_.size(); j++) {
            qint64 v = qint64(wave_->valueAt(sigs_[j], t));
            if (v == last[j]) continue;
            last[j] = v;
            if (sigs_[j].bits.size() == 1) o << v << ids[j] << "\n";
            else o << "b" << QString::number(quint64(v), 2) << " " << ids[j] << "\n";
        }
    }
    log_->appendPlainText("wrote " + p);
}

void MainWindow::saveCapture()
{
    if (samples_.isEmpty()) { QMessageBox::information(this, "save", "nothing captured yet"); return; }
    QString p = QFileDialog::getSaveFileName(this, "save capture", "capture.json", "capture (*.json)");
    if (p.isEmpty()) return;
    QJsonObject o;
    o["width"] = widthSpin_->value(); o["depth"] = depthSpin_->value(); o["clk_ns"] = clkSpin_->value();
    o["post"] = lastPost_; o["triggered"] = lastStatus_.trig;
    QJsonArray sig;
    for (const auto &s : sigs_) { QJsonArray b; for (int k : s.bits) b.append(k); sig.append(QJsonObject{{"name", s.name}, {"bits", b}}); }
    o["signals"] = sig;
    QJsonArray sm;
    for (const auto &s : samples_) sm.append(s.hex());
    o["samples"] = sm;
    QFile f(p);
    if (!f.open(QIODevice::WriteOnly)) { onError("cannot write " + p); return; }
    f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
    log_->appendPlainText("saved " + p);
}

void MainWindow::loadCapture()
{
    QString p = QFileDialog::getOpenFileName(this, "load capture", "", "capture (*.json)");
    if (p.isEmpty()) return;
    QFile f(p);
    if (!f.open(QIODevice::ReadOnly)) { onError("cannot read " + p); return; }
    QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    int W = o["width"].toInt(64);
    widthSpin_->setValue(W); depthSpin_->setValue(o["depth"].toInt(1024)); clkSpin_->setValue(o["clk_ns"].toDouble(8.0));
    lastPost_ = o["post"].toInt();
    sigs_.clear();
    for (const auto &v : o["signals"].toArray()) {
        Signal s; s.name = v.toObject()["name"].toString();
        for (const auto &b : v.toObject()["bits"].toArray()) s.bits.append(b.toInt());
        sigs_.append(s);
    }
    rebuildTriggerTable();
    samples_.clear();
    for (const auto &v : o["samples"].toArray()) samples_.append(Bits::fromHex(v.toString(), W));
    lastStatus_ = IlaStatus(); lastStatus_.trig = o["triggered"].toBool(); lastStatus_.done = true;
    wave_->setCapture(samples_, lastStatus_.trig ? samples_.size() - 1 - lastPost_ : -1, clkSpin_->value());
    log_->appendPlainText(QString("loaded %1: %2 samples").arg(p).arg(samples_.size()));
}

void MainWindow::openMap(const QString &path)
{
    mapEdit_->setText(path);
    loadMap(path);
}
