#pragma once
#include "ila.h"
#include "waveform.h"
#include <QMainWindow>

class QLineEdit; class QSpinBox; class QDoubleSpinBox; class QTableWidget; class QLabel; class QPlainTextEdit;
class QPushButton; class QCheckBox; class QTimer; class QComboBox; class QScrollBar;

class MainWindow : public QMainWindow
{
    Q_OBJECT
public:
    MainWindow();
    void openMap(const QString &path);

private:
    Ila ila_;
    Waveform *wave_;
    QScrollBar *hscroll_;
    QVector<Signal> sigs_;
    QVector<Bits> samples_;
    IlaStatus lastStatus_;
    int lastPost_ = 0;

    // settings
    QLineEdit *oflEdit_, *cableEdit_, *mapEdit_;
    QSpinBox *widthSpin_, *depthSpin_, *ctlSpin_, *datSpin_, *freqSpin_, *postSpin_;
    QDoubleSpinBox *clkSpin_;
    QTableWidget *trig_;
    QLabel *statusLbl_;
    QPlainTextEdit *log_;
    QPushButton *armBtn_, *disarmBtn_, *statusBtn_, *readBtn_;
    QCheckBox *pollChk_;
    QTimer *poll_;

    void applyConfig();
    void loadMap(const QString &path);
    void rebuildTriggerTable();
    bool triggerWord(Bits &mask, Bits &value, QString &err) const;
    void doArm();
    void onStatus(IlaStatus st);
    void onCapture(IlaStatus st, QVector<Bits> samples);
    void onError(const QString &what);
    void exportVcd();
    void saveCapture();
    void loadCapture();
    void setBusy(bool b);
};
