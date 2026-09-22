#include "waveform.h"
#include <QMouseEvent>
#include <QPainter>
#include <QWheelEvent>
#include <cmath>

Waveform::Waveform(QWidget *parent) : QWidget(parent)
{
    setFocusPolicy(Qt::StrongFocus);
    setMouseTracking(false);
    setAutoFillBackground(true);
    QPalette p = palette();
    p.setColor(QPalette::Window, QColor(24, 26, 32));
    setPalette(p);
}

void Waveform::setSignals(const QVector<Signal> &sigs)
{
    sigs_ = sigs;
    setMinimumHeight(axisH_ + rowH_ * sigs_.size() + 8);
    update();
}

void Waveform::setCapture(const QVector<Bits> &samples, int trigger, double clkNs)
{
    samples_ = samples;
    trigger_ = trigger;
    clkNs_ = clkNs;
    cursor_ = trigger >= 0 ? trigger : 0;
    zoomFit();
    emit cursorMoved(cursor_);
}

void Waveform::clear()
{
    samples_.clear();
    trigger_ = -1;
    cursor_ = -1;
    update();
}

uint64_t Waveform::valueAt(const Signal &s, int t) const
{
    if (t < 0 || t >= samples_.size()) return 0;
    uint64_t v = 0;
    for (int i = 0; i < s.bits.size() && i < 64; i++) v |= uint64_t(samples_[t].get(s.bits[i])) << i;
    return v;
}

void Waveform::setCursor(int t)
{
    if (samples_.isEmpty()) return;
    cursor_ = qBound(0, t, samples_.size() - 1);
    if (xOf(cursor_) < nameW_ || xOf(cursor_ + 1) > width()) {   // keep it in view
        t0_ = cursor_ - (width() - nameW_) / pxPerSample_ / 2;
        clampView();
        emit viewChanged();
    }
    update();
    emit cursorMoved(cursor_);
}

void Waveform::zoomFit()
{
    if (samples_.isEmpty()) return;
    pxPerSample_ = double(qMax(1, width() - nameW_)) / samples_.size();
    t0_ = 0;
    update();
    emit viewChanged();
}

void Waveform::clampView()
{
    double vis = (width() - nameW_) / pxPerSample_;
    t0_ = qBound(0.0, t0_, qMax(0.0, samples_.size() - vis));
}

void Waveform::paintEvent(QPaintEvent *)
{
    QPainter g(this);
    g.setRenderHint(QPainter::Antialiasing, false);
    const QColor grid(50, 54, 64), text(220, 220, 220), dim(140, 140, 150), hi(90, 200, 120), busFill(40, 60, 90),
            busEdge(120, 170, 230), cursorC(255, 210, 60), trigC(255, 90, 90);
    g.fillRect(0, 0, nameW_, height(), QColor(32, 34, 42));
    g.setPen(grid);
    g.drawLine(nameW_, 0, nameW_, height());

    const int n = samples_.size();
    const int plotW = width() - nameW_;
    if (n == 0) {
        g.setPen(dim);
        g.drawText(rect(), Qt::AlignCenter, "no capture -- arm, run the design, read");
        return;
    }
    // ---- time axis ----
    double vis = plotW / pxPerSample_;
    double step = 1;                        // 1, 2, 5, 10, 20, 50, ... samples per tick
    for (int k = 0; step * pxPerSample_ < 70; k++) step *= (k % 3 == 1) ? 2.5 : 2;
    g.setPen(dim);
    g.setFont(QFont("monospace", 8));
    for (double t = std::floor(t0_ / step) * step; t < t0_ + vis + step; t += step) {
        int x = int(xOf(t));
        if (x < nameW_ || x > width()) continue;
        g.setPen(grid);
        g.drawLine(x, axisH_, x, height());
        g.setPen(dim);
        g.drawText(x + 2, 11, QString::number(qint64(t)));
        g.drawText(x + 2, 23, QString("%1 ns").arg(t * clkNs_, 0, 'f', 0));
    }
    // ---- rows ----
    g.setFont(QFont("monospace", 9));
    int visT0 = qMax(0, int(std::floor(t0_)) - 1), visT1 = qMin(n, int(std::ceil(t0_ + vis)) + 2);
    for (int r = 0; r < sigs_.size(); r++) {
        const Signal &s = sigs_[r];
        int y = axisH_ + r * rowH_, top = y + 4, bot = y + rowH_ - 4;
        g.setPen(grid);
        g.drawLine(nameW_, y + rowH_, width(), y + rowH_);
        // name and cursor value
        g.setPen(text);
        QString label = s.name;
        if (cursor_ >= 0) {
            uint64_t v = valueAt(s, cursor_);
            label += s.bits.size() == 1 ? QString(" = %1").arg(v) : QString(" = %1").arg(v, (s.bits.size() + 3) / 4, 16, QChar('0'));
        }
        g.drawText(QRect(6, y, nameW_ - 10, rowH_), Qt::AlignVCenter | Qt::AlignLeft, g.fontMetrics().elidedText(label, Qt::ElideLeft, nameW_ - 12));
        g.setClipRect(nameW_, y, plotW, rowH_);
        if (s.bits.size() == 1) {
            g.setPen(QPen(hi, 1));
            int b = s.bits[0];
            int prevY = -1;
            for (int t = visT0; t < visT1; t++) {
                int yy = samples_[t].get(b) ? top : bot;
                int x0 = int(xOf(t)), x1 = int(xOf(t + 1));
                if (prevY >= 0 && prevY != yy) g.drawLine(x0, prevY, x0, yy);
                g.drawLine(x0, yy, x1, yy);
                prevY = yy;
            }
        } else {
            // boxes between value changes
            int t = visT0;
            while (t < visT1) {
                uint64_t v = valueAt(s, t);
                int t2 = t + 1;
                while (t2 < n && valueAt(s, t2) == v) t2++;
                int x0 = int(xOf(t)), x1 = int(xOf(t2));
                QRect box(x0, top, qMax(1, x1 - x0), bot - top);
                g.fillRect(box, busFill);
                g.setPen(busEdge);
                g.drawRect(box.adjusted(0, 0, -1, -1));
                QString txt = QString("%1").arg(v, (s.bits.size() + 3) / 4, 16, QChar('0'));
                if (g.fontMetrics().horizontalAdvance(txt) + 6 < box.width()) {
                    g.setPen(text);
                    g.drawText(box, Qt::AlignCenter, txt);
                }
                t = t2;
            }
        }
        g.setClipping(false);
    }
    // ---- trigger and cursor ----
    if (trigger_ >= 0) {
        int x = int(xOf(trigger_));
        if (x >= nameW_ && x <= width()) {
            g.setPen(QPen(trigC, 1, Qt::DashLine));
            g.drawLine(x, axisH_, x, height());
            g.setPen(trigC);
            g.drawText(x + 3, height() - 4, "T");
        }
    }
    if (cursor_ >= 0) {
        int x = int(xOf(cursor_ + 0.5));
        if (x >= nameW_ && x <= width()) {
            g.setPen(QPen(cursorC, 1));
            g.drawLine(x, axisH_ - 4, x, height());
            g.setPen(cursorC);
            g.drawText(QRect(6, 0, nameW_ - 10, axisH_), Qt::AlignVCenter | Qt::AlignLeft,
                       QString("sample %1  t = %2 ns").arg(cursor_).arg(cursor_ * clkNs_, 0, 'f', 1));
        }
    }
}

void Waveform::wheelEvent(QWheelEvent *e)
{
    if (samples_.isEmpty()) return;
    double tAtMouse = tOf(e->position().x());
    double f = e->angleDelta().y() > 0 ? 1.25 : 0.8;
    pxPerSample_ = qBound(double(width() - nameW_) / samples_.size(), pxPerSample_ * f, 200.0);
    t0_ = tAtMouse - (e->position().x() - nameW_) / pxPerSample_;
    clampView();
    update();
    emit viewChanged();
}

void Waveform::mousePressEvent(QMouseEvent *e)
{
    if (e->button() != Qt::LeftButton) return;
    dragging_ = true; dragged_ = false;
    dragStart_ = e->pos(); dragT0_ = t0_;
}

void Waveform::mouseMoveEvent(QMouseEvent *e)
{
    if (!dragging_ || samples_.isEmpty()) return;
    int dx = e->pos().x() - dragStart_.x();
    if (qAbs(dx) > 3) dragged_ = true;
    if (dragged_) {
        t0_ = dragT0_ - dx / pxPerSample_;
        clampView();
        update();
        emit viewChanged();
    }
}

void Waveform::mouseReleaseEvent(QMouseEvent *e)
{
    if (e->button() != Qt::LeftButton) return;
    dragging_ = false;
    if (!dragged_ && e->pos().x() >= nameW_ && !samples_.isEmpty()) {
        cursor_ = qBound(0, int(std::floor(tOf(e->pos().x()))), samples_.size() - 1);
        update();
        emit cursorMoved(cursor_);
    }
}

void Waveform::keyPressEvent(QKeyEvent *e)
{
    if (samples_.isEmpty()) return;
    switch (e->key()) {
    case Qt::Key_Left: setCursor(cursor_ - 1); break;
    case Qt::Key_Right: setCursor(cursor_ + 1); break;
    case Qt::Key_Home: setCursor(0); break;
    case Qt::Key_End: setCursor(samples_.size() - 1); break;
    case Qt::Key_T: if (trigger_ >= 0) setCursor(trigger_); break;
    case Qt::Key_F: zoomFit(); break;
    default: QWidget::keyPressEvent(e);
    }
}

void Waveform::resizeEvent(QResizeEvent *)
{
    clampView();
    emit viewChanged();
}
