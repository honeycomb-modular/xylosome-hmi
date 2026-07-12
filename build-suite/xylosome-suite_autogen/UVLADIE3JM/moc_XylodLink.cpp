/****************************************************************************
** Meta object code from reading C++ file 'XylodLink.h'
**
** Created by: The Qt Meta Object Compiler version 69 (Qt 6.11.1)
**
** WARNING! All changes made in this file will be lost!
*****************************************************************************/

#include "../../../suite/src/XylodLink.h"
#include <QtCore/qmetatype.h>

#include <QtCore/qtmochelpers.h>

#include <memory>


#include <QtCore/qxptype_traits.h>
#if !defined(Q_MOC_OUTPUT_REVISION)
#error "The header file 'XylodLink.h' doesn't include <QObject>."
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
struct qt_meta_tag_ZN9XylodLinkE_t {};
} // unnamed namespace

template <> constexpr inline auto XylodLink::qt_create_metaobjectdata<qt_meta_tag_ZN9XylodLinkE_t>()
{
    namespace QMC = QtMocConstants;
    QtMocHelpers::StringRefStorage qt_stringData {
        "XylodLink",
        "connectedChanged",
        "",
        "hostChanged",
        "portChanged",
        "statusChanged",
        "passIndexChanged",
        "progressChanged",
        "faultTextChanged",
        "passStarted",
        "pass",
        "filter",
        "tMs",
        "wallMs",
        "passEnded",
        "sequenceDone",
        "passes",
        "faulted",
        "text",
        "onConnected",
        "onDisconnected",
        "onReadyRead",
        "tryConnect",
        "connected",
        "host",
        "port",
        "state",
        "running",
        "estopOk",
        "passIndex",
        "filterName",
        "progress",
        "positionDeg",
        "velocityDegS",
        "lineHz",
        "faultText",
        "sim"
    };

    QtMocHelpers::UintData qt_methods {
        // Signal 'connectedChanged'
        QtMocHelpers::SignalData<void()>(1, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'hostChanged'
        QtMocHelpers::SignalData<void()>(3, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'portChanged'
        QtMocHelpers::SignalData<void()>(4, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'statusChanged'
        QtMocHelpers::SignalData<void()>(5, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'passIndexChanged'
        QtMocHelpers::SignalData<void()>(6, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'progressChanged'
        QtMocHelpers::SignalData<void()>(7, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'faultTextChanged'
        QtMocHelpers::SignalData<void()>(8, 2, QMC::AccessPublic, QMetaType::Void),
        // Signal 'passStarted'
        QtMocHelpers::SignalData<void(int, const QString &, qint64, qint64)>(9, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 10 }, { QMetaType::QString, 11 }, { QMetaType::LongLong, 12 }, { QMetaType::LongLong, 13 },
        }}),
        // Signal 'passEnded'
        QtMocHelpers::SignalData<void(int, qint64, qint64)>(14, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 10 }, { QMetaType::LongLong, 12 }, { QMetaType::LongLong, 13 },
        }}),
        // Signal 'sequenceDone'
        QtMocHelpers::SignalData<void(int)>(15, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::Int, 16 },
        }}),
        // Signal 'faulted'
        QtMocHelpers::SignalData<void(const QString &)>(17, 2, QMC::AccessPublic, QMetaType::Void, {{
            { QMetaType::QString, 18 },
        }}),
        // Slot 'onConnected'
        QtMocHelpers::SlotData<void()>(19, 2, QMC::AccessPrivate, QMetaType::Void),
        // Slot 'onDisconnected'
        QtMocHelpers::SlotData<void()>(20, 2, QMC::AccessPrivate, QMetaType::Void),
        // Slot 'onReadyRead'
        QtMocHelpers::SlotData<void()>(21, 2, QMC::AccessPrivate, QMetaType::Void),
        // Slot 'tryConnect'
        QtMocHelpers::SlotData<void()>(22, 2, QMC::AccessPrivate, QMetaType::Void),
    };
    QtMocHelpers::UintData qt_properties {
        // property 'connected'
        QtMocHelpers::PropertyData<bool>(23, QMetaType::Bool, QMC::DefaultPropertyFlags, 0),
        // property 'host'
        QtMocHelpers::PropertyData<QString>(24, QMetaType::QString, QMC::DefaultPropertyFlags | QMC::Writable | QMC::StdCppSet, 1),
        // property 'port'
        QtMocHelpers::PropertyData<int>(25, QMetaType::Int, QMC::DefaultPropertyFlags | QMC::Writable | QMC::StdCppSet, 2),
        // property 'state'
        QtMocHelpers::PropertyData<QString>(26, QMetaType::QString, QMC::DefaultPropertyFlags, 3),
        // property 'running'
        QtMocHelpers::PropertyData<bool>(27, QMetaType::Bool, QMC::DefaultPropertyFlags, 3),
        // property 'estopOk'
        QtMocHelpers::PropertyData<bool>(28, QMetaType::Bool, QMC::DefaultPropertyFlags, 3),
        // property 'passIndex'
        QtMocHelpers::PropertyData<int>(29, QMetaType::Int, QMC::DefaultPropertyFlags, 4),
        // property 'filterName'
        QtMocHelpers::PropertyData<QString>(30, QMetaType::QString, QMC::DefaultPropertyFlags, 4),
        // property 'progress'
        QtMocHelpers::PropertyData<double>(31, QMetaType::Double, QMC::DefaultPropertyFlags, 5),
        // property 'positionDeg'
        QtMocHelpers::PropertyData<double>(32, QMetaType::Double, QMC::DefaultPropertyFlags, 3),
        // property 'velocityDegS'
        QtMocHelpers::PropertyData<double>(33, QMetaType::Double, QMC::DefaultPropertyFlags, 3),
        // property 'lineHz'
        QtMocHelpers::PropertyData<double>(34, QMetaType::Double, QMC::DefaultPropertyFlags, 3),
        // property 'faultText'
        QtMocHelpers::PropertyData<QString>(35, QMetaType::QString, QMC::DefaultPropertyFlags, 6),
        // property 'sim'
        QtMocHelpers::PropertyData<bool>(36, QMetaType::Bool, QMC::DefaultPropertyFlags, 0),
    };
    QtMocHelpers::UintData qt_enums {
    };
    return QtMocHelpers::metaObjectData<XylodLink, qt_meta_tag_ZN9XylodLinkE_t>(QMC::MetaObjectFlag{}, qt_stringData,
            qt_methods, qt_properties, qt_enums);
}
Q_CONSTINIT const QMetaObject XylodLink::staticMetaObject = { {
    QMetaObject::SuperData::link<QObject::staticMetaObject>(),
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN9XylodLinkE_t>.stringdata,
    qt_staticMetaObjectStaticContent<qt_meta_tag_ZN9XylodLinkE_t>.data,
    qt_static_metacall,
    nullptr,
    qt_staticMetaObjectRelocatingContent<qt_meta_tag_ZN9XylodLinkE_t>.metaTypes,
    nullptr
} };

void XylodLink::qt_static_metacall(QObject *_o, QMetaObject::Call _c, int _id, void **_a)
{
    auto *_t = static_cast<XylodLink *>(_o);
    if (_c == QMetaObject::InvokeMetaMethod) {
        switch (_id) {
        case 0: _t->connectedChanged(); break;
        case 1: _t->hostChanged(); break;
        case 2: _t->portChanged(); break;
        case 3: _t->statusChanged(); break;
        case 4: _t->passIndexChanged(); break;
        case 5: _t->progressChanged(); break;
        case 6: _t->faultTextChanged(); break;
        case 7: _t->passStarted((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<QString>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[3])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[4]))); break;
        case 8: _t->passEnded((*reinterpret_cast<std::add_pointer_t<int>>(_a[1])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[2])),(*reinterpret_cast<std::add_pointer_t<qint64>>(_a[3]))); break;
        case 9: _t->sequenceDone((*reinterpret_cast<std::add_pointer_t<int>>(_a[1]))); break;
        case 10: _t->faulted((*reinterpret_cast<std::add_pointer_t<QString>>(_a[1]))); break;
        case 11: _t->onConnected(); break;
        case 12: _t->onDisconnected(); break;
        case 13: _t->onReadyRead(); break;
        case 14: _t->tryConnect(); break;
        default: ;
        }
    }
    if (_c == QMetaObject::IndexOfMethod) {
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::connectedChanged, 0))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::hostChanged, 1))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::portChanged, 2))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::statusChanged, 3))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::passIndexChanged, 4))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::progressChanged, 5))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)()>(_a, &XylodLink::faultTextChanged, 6))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)(int , const QString & , qint64 , qint64 )>(_a, &XylodLink::passStarted, 7))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)(int , qint64 , qint64 )>(_a, &XylodLink::passEnded, 8))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)(int )>(_a, &XylodLink::sequenceDone, 9))
            return;
        if (QtMocHelpers::indexOfMethod<void (XylodLink::*)(const QString & )>(_a, &XylodLink::faulted, 10))
            return;
    }
    if (_c == QMetaObject::ReadProperty) {
        void *_v = _a[0];
        switch (_id) {
        case 0: *reinterpret_cast<bool*>(_v) = _t->connected(); break;
        case 1: *reinterpret_cast<QString*>(_v) = _t->host(); break;
        case 2: *reinterpret_cast<int*>(_v) = _t->port(); break;
        case 3: *reinterpret_cast<QString*>(_v) = _t->state(); break;
        case 4: *reinterpret_cast<bool*>(_v) = _t->running(); break;
        case 5: *reinterpret_cast<bool*>(_v) = _t->estopOk(); break;
        case 6: *reinterpret_cast<int*>(_v) = _t->passIndex(); break;
        case 7: *reinterpret_cast<QString*>(_v) = _t->filterName(); break;
        case 8: *reinterpret_cast<double*>(_v) = _t->progress(); break;
        case 9: *reinterpret_cast<double*>(_v) = _t->positionDeg(); break;
        case 10: *reinterpret_cast<double*>(_v) = _t->velocityDegS(); break;
        case 11: *reinterpret_cast<double*>(_v) = _t->lineHz(); break;
        case 12: *reinterpret_cast<QString*>(_v) = _t->faultText(); break;
        case 13: *reinterpret_cast<bool*>(_v) = _t->sim(); break;
        default: break;
        }
    }
    if (_c == QMetaObject::WriteProperty) {
        void *_v = _a[0];
        switch (_id) {
        case 1: _t->setHost(*reinterpret_cast<QString*>(_v)); break;
        case 2: _t->setPort(*reinterpret_cast<int*>(_v)); break;
        default: break;
        }
    }
}

const QMetaObject *XylodLink::metaObject() const
{
    return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;
}

void *XylodLink::qt_metacast(const char *_clname)
{
    if (!_clname) return nullptr;
    if (!strcmp(_clname, qt_staticMetaObjectStaticContent<qt_meta_tag_ZN9XylodLinkE_t>.strings))
        return static_cast<void*>(this);
    return QObject::qt_metacast(_clname);
}

int XylodLink::qt_metacall(QMetaObject::Call _c, int _id, void **_a)
{
    _id = QObject::qt_metacall(_c, _id, _a);
    if (_id < 0)
        return _id;
    if (_c == QMetaObject::InvokeMetaMethod) {
        if (_id < 15)
            qt_static_metacall(this, _c, _id, _a);
        _id -= 15;
    }
    if (_c == QMetaObject::RegisterMethodArgumentMetaType) {
        if (_id < 15)
            *reinterpret_cast<QMetaType *>(_a[0]) = QMetaType();
        _id -= 15;
    }
    if (_c == QMetaObject::ReadProperty || _c == QMetaObject::WriteProperty
            || _c == QMetaObject::ResetProperty || _c == QMetaObject::BindableProperty
            || _c == QMetaObject::RegisterPropertyMetaType) {
        qt_static_metacall(this, _c, _id, _a);
        _id -= 14;
    }
    return _id;
}

// SIGNAL 0
void XylodLink::connectedChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 0, nullptr);
}

// SIGNAL 1
void XylodLink::hostChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 1, nullptr);
}

// SIGNAL 2
void XylodLink::portChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 2, nullptr);
}

// SIGNAL 3
void XylodLink::statusChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 3, nullptr);
}

// SIGNAL 4
void XylodLink::passIndexChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 4, nullptr);
}

// SIGNAL 5
void XylodLink::progressChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 5, nullptr);
}

// SIGNAL 6
void XylodLink::faultTextChanged()
{
    QMetaObject::activate(this, &staticMetaObject, 6, nullptr);
}

// SIGNAL 7
void XylodLink::passStarted(int _t1, const QString & _t2, qint64 _t3, qint64 _t4)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 7, nullptr, _t1, _t2, _t3, _t4);
}

// SIGNAL 8
void XylodLink::passEnded(int _t1, qint64 _t2, qint64 _t3)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 8, nullptr, _t1, _t2, _t3);
}

// SIGNAL 9
void XylodLink::sequenceDone(int _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 9, nullptr, _t1);
}

// SIGNAL 10
void XylodLink::faulted(const QString & _t1)
{
    QMetaObject::activate<void>(this, &staticMetaObject, 10, nullptr, _t1);
}
QT_WARNING_POP
