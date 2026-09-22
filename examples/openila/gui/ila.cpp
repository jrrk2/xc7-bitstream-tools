#include "ila.h"
#include <QRegularExpression>

QString IlaStatus::text() const
{
    QString s = armed ? "armed" : "idle";
    if (trig) s += ", triggered";
    if (done) s += ", done";
    s += QString("; waddr=%1").arg(waddr);
    if (!keyOk) s += "  (BAD KEY: wrong chain or no ILA?)";
    return s;
}

QString Bits::hex() const
{
    QString h;
    for (int i = b.size() - 1; i >= 0; i--)
        h += QString("%1").arg(int(b[i]), 2, 16, QChar('0'));
    // strip leading zeros but keep one digit
    int k = 0;
    while (k < h.size() - 1 && h[k] == '0') k++;
    return h.mid(k);
}

Bits Bits::fromHex(const QString &h, int nbits)
{
    Bits r(nbits);
    int bit = 0;
    for (int i = h.size() - 1; i >= 0 && bit < r.size(); i--, bit += 4) {
        bool ok; int v = QString(h[i]).toInt(&ok, 16);
        if (!ok) continue;
        for (int j = 0; j < 4 && bit + j < r.size(); j++) r.set(bit + j, (v >> j) & 1);
    }
    return r;
}

Ila::Ila(QObject *parent) : QObject(parent) {}

Bits Ila::ctlWord(const Bits &mask, const Bits &value, int post, bool arm) const
{
    int W = cfg.width, AW = cfg.aw();
    Bits w(cfg.cw());
    for (int i = 0; i < W; i++) { w.set(i, i < mask.size() && mask.get(i)); w.set(W + i, i < value.size() && value.get(i)); }
    w.put(2 * W, AW, uint64_t(post));
    w.set(2 * W + AW, arm);
    w.put(2 * W + AW + 1, 8, 0x5A);
    return w;
}

IlaStatus Ila::decodeStatus(const Bits &b, int lsb) const
{
    int AW = cfg.aw();
    IlaStatus st;
    st.waddr = int(b.field(lsb, AW));
    st.armed = b.get(lsb + AW);
    st.trig = b.get(lsb + AW + 1);
    st.done = b.get(lsb + AW + 2);
    st.keyOk = b.field(lsb + AW + 3, 8) == 0x1A;
    return st;
}

void Ila::status()
{
    enqueue(cfg.ctl, cfg.cw(), Bits(cfg.cw()), [this](const Bits &rx) { emit statusReady(decodeStatus(rx)); });
}

void Ila::disarm()
{
    Bits z(cfg.width);
    enqueue(cfg.ctl, cfg.cw(), ctlWord(z, z, 0, false), [this](const Bits &rx) { emit statusReady(decodeStatus(rx)); });
}

void Ila::arm(const Bits &mask, const Bits &value, int post)
{
    // drop a previous arm first: ARM is a level, and a re-arm needs the edge
    enqueue(cfg.ctl, cfg.cw(), ctlWord(mask, value, post, false), [](const Bits &) {});
    enqueue(cfg.ctl, cfg.cw(), ctlWord(mask, value, post, true), [this](const Bits &rx) { emit statusReady(decodeStatus(rx)); });
}

void Ila::read()
{
    int W = cfg.width, D = cfg.depth;
    enqueue(cfg.dat, (D + 1) * W, Bits((D + 1) * W), [this, W, D](const Bits &rx) {
        IlaStatus st = decodeStatus(rx, 0);   // the header word
        QVector<Bits> raw(D);
        for (int i = 0; i < D; i++) {
            Bits s(W);
            for (int k = 0; k < W; k++) s.set(k, rx.get(W * (i + 1) + k));
            raw[i] = s;
        }
        QVector<Bits> ordered(D);            // oldest first: the ring starts at waddr
        for (int i = 0; i < D; i++) ordered[i] = raw[(st.waddr + i) % D];
        emit captureReady(st, ordered);
    });
}

void Ila::enqueue(int chain, int nbits, const Bits &tx, std::function<void(const Bits &)> done)
{
    queue_.push({chain, nbits, tx.hex(), std::move(done)});
    if (!running_) next();
}

void Ila::next()
{
    if (queue_.empty()) { running_ = false; emit busyChanged(false); return; }
    running_ = true;
    emit busyChanged(true);
    Job job = queue_.front();
    queue_.pop();
    proc_ = new QProcess(this);
    QStringList args{"--cable", cfg.cable, "--freq", QString::number(cfg.freq),
                     "--user-dr", QString("%1/%2/%3").arg(job.chain).arg(job.nbits).arg(job.hex)};
    emit log(cfg.ofl + " " + args.join(' ').left(120) + (job.hex.size() > 40 ? "..." : ""));
    QProcess *p = proc_;
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this, p, job](int, QProcess::ExitStatus) {
                QString out = QString::fromUtf8(p->readAllStandardOutput()) + QString::fromUtf8(p->readAllStandardError());
                p->deleteLater();
                QRegularExpression re(QString("USER%1 out ([0-9a-fA-F]+)").arg(job.chain));
                auto m = re.match(out);
                if (!m.hasMatch()) {
                    while (!queue_.empty()) queue_.pop();
                    running_ = false;
                    emit busyChanged(false);
                    emit error("openFPGALoader gave no USER" + QString::number(job.chain) + " data:\n" + out.right(600));
                    return;
                }
                job.done(Bits::fromHex(m.captured(1), job.nbits));
                next();
            });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
        while (!queue_.empty()) queue_.pop();
        running_ = false;
        emit busyChanged(false);
        emit error("cannot run " + cfg.ofl + ": " + p->errorString());
        p->deleteLater();
    });
    p->start(cfg.ofl, args);
}
