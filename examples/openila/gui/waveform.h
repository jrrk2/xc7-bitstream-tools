// waveform -- the capture as traces: one row per probed signal, bits as
// square waves, buses as boxes with the value in hex; wheel zooms about the
// mouse, drag pans, click places the cursor, whose values show by the names.
#pragma once
#include "ila.h"
#include <QWidget>

struct Signal
{
    QString name;
    QVector<int> bits;     // probe bit indices, LSB first
};

class Waveform : public QWidget
{
    Q_OBJECT
public:
    explicit Waveform(QWidget *parent = nullptr);
    void setSignals(const QVector<Signal> &sigs);
    void setCapture(const QVector<Bits> &samples, int trigger, double clkNs);
    void clear();
    uint64_t valueAt(const Signal &s, int t) const;
    QSize minimumSizeHint() const override { return {400, 200}; }
    int cursor() const { return cursor_; }
    void setCursor(int t);
    void zoomFit();
    void zoomTo(double t0, double pxPerSample) { t0_ = t0; pxPerSample_ = pxPerSample; clampView(); update(); }

signals:
    void cursorMoved(int t);

protected:
    void paintEvent(QPaintEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void keyPressEvent(QKeyEvent *) override;

private:
    QVector<Signal> sigs_;
    QVector<Bits> samples_;
    int trigger_ = -1;
    double clkNs_ = 8.0;
    double t0_ = 0, pxPerSample_ = 8;   // view: first sample at the left edge, scale
    int cursor_ = -1;
    int rowH_ = 22, nameW_ = 220, axisH_ = 28;
    QPoint dragStart_; double dragT0_ = 0; bool dragging_ = false, dragged_ = false;
    double xOf(double t) const { return nameW_ + (t - t0_) * pxPerSample_; }
    double tOf(double x) const { return t0_ + (x - nameW_) / pxPerSample_; }
    void clampView();
};
