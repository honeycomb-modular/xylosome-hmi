/****************************************************************************
** Meta object code from reading C++ file 'SessionStore.h'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.11.1)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../suite/src/SessionStore.h"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'SessionStore.h' doesn't include <QObject>."
#elif Q_MOC_OUTPUT_REVISION != 69
#error "This file was generated using the moc from 6.11.1. It"
#error "cannot be used with the include files from this version of Qt."
#error "(The moc has changed too much.)"
#endif

#ifndef Q_CONSTINIT
#define Q_CONSTINIT
#endif

QT_WARNING_PUSH
QT_WARNING_DISABLE_DEPRECATED
QT_WARNING_DISABLE_GCC("-Wuseless-cast")
namespace {
struct qt_meta_tag_ZN12SessionStoreE_t {};
} // unnamed namespace

template <> constexpr inline auto SessionStore::qt_create_metaobjectdata<qt_meta_tag_ZN12SessionStoreE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "SessionStore",
        "captureDirChanged",
        "",
        "countChanged",
        "unpairedFilesChanged",
        "diskChanged",
        "reclaimed",
        "gb",
        "sessions",
        "onPassStarted",
        "pass",
        "filter",
        "tMs",
        "wallMs",
        "onPassEnded",
        "onSequenceDone",
        "passes",
        "onFaulted",
        "text",
        "onLinkDropped",
        "onFileReady",
        "absPath",
        "mtimeMs",
        "onIngested",
        "sessionUuid",
        "passIndex",
        "previewAbs",
        "pxW",
        "pxH",
        "clipBlackPct",
        "clipWhitePct",
        "QVariantList",
        "hist256",
        "setRating",
        "row",
        "rating",
        "setRejected",
        "rejected",
        "setNote",
        "note",
        "setMetaPlacement",
        "x",
        "y",
        "w",
        "setMetaWhite",
        "white",
        "sessionGB",
        "deleteSession",
        "emptyQuarantine",
        "scanArchive",
        "dir",
        "importArchive",
        "captureDir",
        "count",
        "liveRow",
        "unpairedFiles",
        "freeGB",
        "sessionsRemaining",
        "rejectedCount"
    };

    QtMocHelpers::UintData qt_methods {
        // Signal 'captureDirChanged'
        QtMocHelpers::SignalData<void()>(1, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'countChanged'
        QtMocHelpers::SignalData<void()>(3, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'unpairedFilesChanged'
        QtMocHelpers::SignalData<void()>(4, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'diskChanged'
        QtMocHelpers::SignalData<void()>(5, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'reclaimed'
        QtMocHelpers::SignalData<void(double, int)>(6, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Double, 7 }, { QMetaType::Int, 8 },
        }}),
        // Slot 'onPassStarted'
        QtMocHelpers::SlotData<void(int, const QString &, qint64, qint64)>(9, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 10 }, { QMetaType::QString, 11 }, { QMetaType::LongLong, 12 }, { QMetaType::LongLong, 13 },
        }}),
        // Slot 'onPassEnded'
        QtMocHelpers::SlotData<void(int, qint64, qint64)>(14, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 10 }, { QMetaType::LongLong, 12 }, { QMetaType::LongLong, 13 },
        }}),
        // Slot 'onSequenceDone'
        QtMocHelpers::SlotData<void(int)>(15, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::Int, 16 },
        }}),
        // Slot 'onFaulted'
        QtMocHelpers::SlotData<void(const QString &)>(17, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::QString, 18 },
        }}),
        // Slot 'onLinkDropped'
        QtMocHelpers::SlotData<void()>(19, 2, QMC::AccessPrivate, QMetaType::Void),
        // Slot 'onFileReady'
        QtMocHelpers::SlotData<void(const QString &, qint64)>(20, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::QString, 21 }, { QMetaType::LongLong, 22 },
        }}),
        // Slot 'onIngested'
        QtMocHelpers::SlotData<void(const QString &, int, const QString &, int, int, double, double, const QVariantList &)>(23, 2, QMC::AccessPrivate, QMetaType::Void, {{
            { QMetaType::QString, 24 }, { QMetaType::Int, 25 }, { QMetaType::QString, 26 }, { QMetaType::Int, 27 },
            { QMetaType::Int, 28 }, { QMetaType::Double, 29 }, { QMetaType::Double, 30 }, { 0x80000000 | 31, 32 },
        }}),
        // Method 'setRating'
        QtMocHelpers::MethodData<void(int, int)>(33, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 }, { QMetaType::Int, 35 },
        }}),
        // Method 'setRejected'
        QtMocHelpers::MethodData<void(int, bool)>(36, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 }, { QMetaType::Bool, 37 },
        }}),
        // Method 'setNote'
        QtMocHelpers::MethodData<void(int, const QString &)>(38, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 }, { QMetaType::QString, 39 },
        }}),
        // Method 'setMetaPlacement'
        QtMocHelpers::MethodData<void(int, double, double, double)>(40, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 }, { QMetaType::Double, 41 }, { QMetaType::Double, 42 }, { QMetaType::Double, 43 },
        }}),
        // Method 'setMetaWhite'
        QtMocHelpers::MethodData<void(int, bool)>(44, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 }, { QMetaType::Bool, 45 },
        }}),
        // Method 'sessionGB'
        QtMocHelpers::MethodData<double(int) const>(46, 2, QMC::AccessPublic, QMetaType::Double, {{
            { QMetaType::Int, 34 },
        }}),
        // Method 'deleteSession'
        QtMocHelpers::MethodData<void(int)>(47, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 34 },
        }}),
        // Method 'emptyQuarantine'
        QtMocHelpers::MethodData<void()>(48, 2, QMC::AccessPublic, QMetaType::Void),
        // Method 'scanArchive'
        QtMocHelpers::MethodData<QVariantList(const QString &) const>(49, 2, QMC::AccessPublic, 0x80000000 | 31, {{
            { QMetaType::QString, 50 },
        }}),
        // Method 'importArchive'
        QtMocHelpers::MethodData<int(const QString &)>(51, 2, QMC::AccessPublic, QMetaType::Int, {{
            { QMetaType::QString, 50 },
        }}),
    };
    QtMocHelpers::UintData qt_properties {
        // property 'captureDir'
        QtMocHelpers::PropertyData<QString>(52, QMetaType::QString, QMC::DefaultPropertyFlags | QMC::Writable | QMC::StdCppSet, 0),
        // property 'count'
        QtMocHelpers::PropertyData<int>(53, QMetaType::Int, QMC::DefaultPropertyFlags, 1),
        // property 'liveRow'
        QtMocHelpers::PropertyData<int>(54, QMetaType::Int, QMC::DefaultPropertyFlags, 1),
        // property 'unpairedFiles'
        QtMocHelpers::PropertyData<int>(55, QMetaType::Int, QMC::DefaultPropertyFlags, 2),
        // property 'freeGB'
        QtMocHelpers::PropertyData<double>(56, QMetaType::Double, QMC::DefaultPropertyFlags, 3),
        // property 'sessionsRemaining'
        QtMocHelpers::PropertyData<int>(57, QMetaType::Int, QMC::DefaultPropertyFlags, 3),
        // property 'rejectedCount'
        QtMocHelpers::PropertyData<int>(58, QMetaType::Int, QMC::DefaultPropertyFlags, 1),
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<SessionStore, qt_meta_tag_ZN12SessionStoreE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject SessionStore::staticMetaObject = { {
    QMetaObject::SuperData::link<QAbstractListModel::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN12SessionStoreE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN12SessionStoreE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN12SessionStoreE_t>.metaTypes,
    nullptr
} };

void SessionStore::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<SessionStore *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->captureDirChanged(); break;
        case 1: _t->countChanged(); break;
        case 2: _t->unpairedFilesChanged(); break;
        case 3: _t->diskChanged(); break;
        case 4: _t->reclaimed((*reinterpret_cast<std::add_pointer_t<double>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[2]))); break;
        case 5: _t->onPassStarted((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[3])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[4]))); break;
        case 6: _t->onPassEnded((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[3]))); break;
        case 7: _t->onSequenceDone((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 8: _t->onFaulted((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1]))); break;
        case 9: _t->onLinkDropped(); break;
        case 10: _t->onFileReady((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[2]))); break;
        case 11: _t->onIngested((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[3])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[4])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[5])),(*reinterpret_cast<std::add_pointer_t<double>>(_a[6])),(*reinterpret_cast<std::add_pointer_t<double>>(_a[7])),(*reinterpret_cast<std::add_pointer_t<QVariantList>>(_a[8]))); break;
        case 12: _t->setRating((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<int>>(_a[2]))); break;
        case 13: _t->setRejected((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<bool>>(_a[2]))); break;
        case 14: _t->setNote((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2]))); break;
        case 15: _t->setMetaPlacement((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<double>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<double>>(_a[3])),(*reinterpret_cast<std::add_pointer_t<double>>(_a[4]))); break;
        case 16: _t->setMetaWhite((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<bool>>(_a[2]))); break;
        case 17: { double _r = _t->sessionGB((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])));
            if (_a[0]) *reinterpret_cast<double*>(_a[0]) = std::move(_r); }  break;
        case 18: _t->deleteSession((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 19: _t->emptyQuarantine(); break;
        case 20: { QVariantList _r = _t->scanArchive((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])));
            if (_a[0]) *reinterpret_cast<QVariantList*>(_a[0]) = std::move(_r); }  break;
        case 21: { int _r = _t->importArchive((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1])));
            if (_a[0]) *reinterpret_cast<int*>(_a[0]) = std::move(_r); }  break;
        default: ;
        }
    }
    if (_c == QMetaObject::IndexOfMethod) {
        if (QtMocHelpers::indexOfMethod<void (SessionStore::*)()>(_a, &SessionStore::captureDirChanged, 0))
            return;
        if (QtMocHelpers::indexOfMethod<void (SessionStore::*)()>(_a, &SessionStore::countChanged, 1))
            return;
        if (QtMocHelpers::indexOfMethod<void (SessionStore::*)()>(_a, &SessionStore::unpairedFilesChanged, 2))
            return;
        if (QtMocHelpers::indexOfMethod<void (SessionStore::*)()>(_a, &SessionStore::diskChanged, 3))
            return;
        if (QtMocHelpers::indexOfMethod<void (SessionStore::*)(double , int )>(_a, &SessionStore::reclaimed, 4))
            return;
    }
    if (_c == QMetaObject::ReadProperty) {
        void *_v = _a[0];
        switch (_id) {
        case 0: *reinterpret_cast<QString*>(_v) = _t->captureDir(); break;
        case 1: *reinterpret_cast<int*>(_v) = _t->rowCount(); break;
        case 2: *reinterpret_cast<int*>(_v) = _t->liveRow(); break;
        case 3: *reinterpret_cast<int*>(_v) = _t->unpairedFiles(); break;
        case 4: *reinterpret_cast<double*>(_v) = _t->freeGB(); break;
        case 5: *reinterpret_cast<int*>(_v) = _t->sessionsRemaining(); break;
        case 6: *reinterpret_cast<int*>(_v) = _t->rejectedCount(); break;
        default: break;
        }
    }
    if (_c == QMetaObject::WriteProperty) {
        void *_v = _a[0];
        switch (_id) {
        case 0: _t->setCaptureDir(*reinterpret_cast<QString*>(_v)); break;
        default: break;
        }
    }
}

const QMetaObject *SessionStore::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *SessionStore::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN12SessionStoreE_t>.strings))
        return static_cast<void*>(this);
    return QAbstractListModel::qt_metacast(_clname);
}

int SessionStore::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QAbstractListModel::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 22)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 22;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 22)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 22;
    }
    if (_c == QMetaObject::ReadProperty || _c == QMetaObject::WriteProperty
            || _c == QMetaObject::ResetProperty || _c == QMetaObject::BindableProperty
            || _c == QMetaObject::RegisterPropertyMetaType) {
        qt_static_metacall(this, _c, _id, _a);
        _id -= 7;
    }
    return _id;
}

// SIGNAL 0
void SessionStore::captureDirChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 0, nullptr);
}

// SIGNAL 1
void SessionStore::countChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 1, nullptr);
}

// SIGNAL 2
void SessionStore::unpairedFilesChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 2, nullptr);
}

// SIGNAL 3
void SessionStore::diskChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 3, nullptr);
}

// SIGNAL 4
void SessionStore::reclaimed(double _t1, int _t2)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 4, nullptr, _t1, _t2);
}
QT_WARNING_POP
