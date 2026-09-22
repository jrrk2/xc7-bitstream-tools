// ila -- the openila driver: register formats and the JTAG transport, which
// is openFPGALoader --user-dr run as a child process, one DR scan per run.
// Everything is asynchronous (QProcess); results come back as signals, so
// the window stays live while a 65-kbit read takes its second or two.
#pragma once
#include <QObject>
#include <QProcess>
#include <QString>
#include <QVector>
#include <cstdint>
#include <functional>
#include <queue>

struct IlaConfig
{
    int width = 64, depth = 1024, ctl = 2, dat = 3;
    QString ofl = QString::fromUtf8(qgetenv("HOME")) + "/openFPGALoader/build-ofl/openFPGALoader";
    QString cable = "digilent";
    int freq = 15000000;
    double clkNs = 8.0;
    int aw() const { int a = 0; while ((1 << a) < depth) a++; return a < 1 ? 1 : a; }
    int cw() const { return 2 * width + aw() + 9; }   // control register
    int sw() const { return aw() + 11; }               // status word
};

struct IlaStatus
{
    int waddr = 0;
    bool armed = false, trig = false, done = false, keyOk = false;
    QString text() const;
};

// A bit vector wide enough for a DR scan, kept as bytes LSB first (bit i is
// byte i/8 bit i%8), which is also openFPGALoader's shift order.
struct Bits
{
    QVector<uint8_t> b;
    explicit Bits(int n = 0) : b((n + 7) / 8, 0) {}
    int size() const { return b.size() * 8; }
    bool get(int i) const { return (b[i / 8] >> (i % 8)) & 1; }
    void set(int i, bool v) { if (v) b[i / 8] |= 1 << (i % 8); else b[i / 8] &= ~(1 << (i % 8)); }
    void put(int lsb, int n, uint64_t v) { for (int i = 0; i < n; i++) set(lsb + i, (v >> i) & 1); }
    uint64_t field(int lsb, int n) const { uint64_t v = 0; for (int i = 0; i < n && i < 64; i++) v |= uint64_t(get(lsb + i)) << i; return v; }
    QString hex() const;                 // most significant digit first, as --user-dr wants
    static Bits fromHex(const QString &h, int nbits);
};

class Ila : public QObject
{
    Q_OBJECT
public:
    explicit Ila(QObject *parent = nullptr);
    IlaConfig cfg;

    void status();
    void arm(const Bits &mask, const Bits &value, int post);
    void disarm();
    void read();
    bool busy() const { return running_ || !queue_.empty(); }

    IlaStatus decodeStatus(const Bits &b, int lsb = 0) const;
    Bits ctlWord(const Bits &mask, const Bits &value, int post, bool arm) const;

signals:
    void statusReady(IlaStatus st);
    void captureReady(IlaStatus st, QVector<Bits> samples);   // oldest sample first
    void error(QString what);
    void busyChanged(bool busy);
    void log(QString line);

private:
    struct Job { int chain; int nbits; QString hex; std::function<void(const Bits &)> done; };
    std::queue<Job> queue_;
    bool running_ = false;
    QProcess *proc_ = nullptr;
    void enqueue(int chain, int nbits, const Bits &tx, std::function<void(const Bits &)> done);
    void next();
};
