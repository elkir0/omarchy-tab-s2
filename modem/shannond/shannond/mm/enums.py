# SPDX-License-Identifier: GPL-2.0-or-later
"""ModemManager 1.24 constants used by the shannon2mm facade.

Values are the public D-Bus API values from ``ModemManager-enums.h``,
``ModemManager-errors.h`` and ``ModemManager-names.h`` (they are part of the
wire protocol, so clients such as mmcli, NetworkManager, GNOME Calls and
Chatty depend on them).  Only the subset the facade uses is listed.
"""

SERVICE = "org.freedesktop.ModemManager1"
ROOT_PATH = "/org/freedesktop/ModemManager1"
MODEM_PREFIX = ROOT_PATH + "/Modem/"
SIM_PREFIX = ROOT_PATH + "/SIM/"
BEARER_PREFIX = ROOT_PATH + "/Bearer/"
SMS_PREFIX = ROOT_PATH + "/SMS/"
CALL_PREFIX = ROOT_PATH + "/Call/"
NO_PATH = "/"

IFACE_MANAGER = SERVICE
IFACE_MODEM = SERVICE + ".Modem"
IFACE_SIMPLE = SERVICE + ".Modem.Simple"
IFACE_3GPP = SERVICE + ".Modem.Modem3gpp"
IFACE_USSD = SERVICE + ".Modem.Modem3gpp.Ussd"
IFACE_MESSAGING = SERVICE + ".Modem.Messaging"
IFACE_VOICE = SERVICE + ".Modem.Voice"
IFACE_SIM = SERVICE + ".Sim"
IFACE_BEARER = SERVICE + ".Bearer"
IFACE_SMS = SERVICE + ".Sms"
IFACE_CALL = SERVICE + ".Call"
IFACE_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
IFACE_PROPERTIES = "org.freedesktop.DBus.Properties"

# MMModemCapability
CAP_NONE = 0
CAP_POTS = 1 << 0
CAP_GSM_UMTS = 1 << 2
CAP_LTE = 1 << 3

# MMModemLock
LOCK_UNKNOWN = 0
LOCK_NONE = 1
LOCK_SIM_PIN = 2
LOCK_SIM_PIN2 = 3
LOCK_SIM_PUK = 4
LOCK_SIM_PUK2 = 5

# MMModemState (signed)
STATE_FAILED = -1
STATE_UNKNOWN = 0
STATE_INITIALIZING = 1
STATE_LOCKED = 2
STATE_DISABLED = 3
STATE_DISABLING = 4
STATE_ENABLING = 5
STATE_ENABLED = 6
STATE_SEARCHING = 7
STATE_REGISTERED = 8
STATE_DISCONNECTING = 9
STATE_CONNECTING = 10
STATE_CONNECTED = 11

# MMModemStateFailedReason
FAILED_NONE = 0
FAILED_UNKNOWN = 1
FAILED_SIM_MISSING = 2
FAILED_SIM_ERROR = 3

# MMModemStateChangeReason
CHANGE_UNKNOWN = 0
CHANGE_USER_REQUESTED = 1
CHANGE_SUSPEND = 2
CHANGE_FAILURE = 3

# MMModemPowerState
POWER_UNKNOWN = 0
POWER_OFF = 1
POWER_LOW = 2
POWER_ON = 3

# MMModemAccessTechnology
ACCESS_UNKNOWN = 0
ACCESS_GSM = 1 << 1
ACCESS_UMTS = 1 << 5
ACCESS_LTE = 1 << 14

# MMModemMode
MODE_NONE = 0
MODE_CS = 1 << 0
MODE_2G = 1 << 1
MODE_3G = 1 << 2
MODE_4G = 1 << 3

# MMModemBand
BAND_UNKNOWN = 0
BAND_ANY = 256

# MMModemPortType
PORT_UNKNOWN = 1
PORT_NET = 2
PORT_AT = 3
PORT_QCDM = 4
PORT_GPS = 5
PORT_QMI = 6
PORT_MBIM = 7
PORT_AUDIO = 8
PORT_IGNORED = 9
PORT_XMMRPC = 10

# MMModem3gppRegistrationState
REG_IDLE = 0
REG_HOME = 1
REG_SEARCHING = 2
REG_DENIED = 3
REG_UNKNOWN = 4
REG_ROAMING = 5

# MMModem3gppFacility
FACILITY_NONE = 0
FACILITY_SIM = 1 << 0

# MMModem3gppPacketServiceState
PS_UNKNOWN = 0
PS_DETACHED = 1
PS_ATTACHED = 2

# MMModem3gppSubscriptionState / EpsUeModeOperation
SUBSCRIPTION_UNKNOWN = 0
EPS_UE_MODE_UNKNOWN = 0

# MMBearerIpMethod
IP_METHOD_UNKNOWN = 0
IP_METHOD_PPP = 1
IP_METHOD_STATIC = 2
IP_METHOD_DHCP = 3

# MMBearerIpFamily
IP_FAMILY_NONE = 0
IP_FAMILY_IPV4 = 1 << 0
IP_FAMILY_IPV6 = 1 << 1
IP_FAMILY_IPV4V6 = 1 << 2
IP_FAMILY_ANY = 0xFFFFFFFF

# MMBearerAllowedAuth
AUTH_UNKNOWN = 0
AUTH_NONE = 1 << 0
AUTH_PAP = 1 << 1
AUTH_CHAP = 1 << 2

# MMBearerType
BEARER_TYPE_DEFAULT = 1

# MMSmsPduType
PDU_UNKNOWN = 0
PDU_DELIVER = 1
PDU_SUBMIT = 2
PDU_STATUS_REPORT = 3

# MMSmsState
SMS_UNKNOWN = 0
SMS_STORED = 1
SMS_RECEIVING = 2
SMS_RECEIVED = 3
SMS_SENDING = 4
SMS_SENT = 5

# MMSmsStorage
STORAGE_UNKNOWN = 0
STORAGE_SM = 1
STORAGE_ME = 2
STORAGE_MT = 3

# MMSmsDeliveryState
DELIVERY_UNKNOWN = 0x100

# MMSmsValidityType
VALIDITY_UNKNOWN = 0

# MMCallState
CALL_UNKNOWN = 0
CALL_DIALING = 1
CALL_RINGING_OUT = 2
CALL_RINGING_IN = 3
CALL_ACTIVE = 4
CALL_HELD = 5
CALL_WAITING = 6
CALL_TERMINATED = 7

# MMCallStateReason
REASON_UNKNOWN = 0
REASON_OUTGOING_STARTED = 1
REASON_INCOMING_NEW = 2
REASON_ACCEPTED = 3
REASON_TERMINATED = 4
REASON_REFUSED_OR_BUSY = 5
REASON_ERROR = 6
REASON_AUDIO_SETUP_FAILED = 7

# MMCallDirection
DIRECTION_UNKNOWN = 0
DIRECTION_INCOMING = 1
DIRECTION_OUTGOING = 2

# D-Bus error names: MM_DBUS_ERROR_PREFIX + "." + domain + "." + nick
ERROR_PREFIX = SERVICE + ".Error"
ERR_FAILED = ERROR_PREFIX + ".Core.Failed"
ERR_CANCELLED = ERROR_PREFIX + ".Core.Cancelled"
ERR_UNSUPPORTED = ERROR_PREFIX + ".Core.Unsupported"
ERR_UNAUTHORIZED = ERROR_PREFIX + ".Core.Unauthorized"
ERR_INVALID_ARGS = ERROR_PREFIX + ".Core.InvalidArgs"
ERR_IN_PROGRESS = ERROR_PREFIX + ".Core.InProgress"
ERR_WRONG_STATE = ERROR_PREFIX + ".Core.WrongState"
ERR_CONNECTED = ERROR_PREFIX + ".Core.Connected"
ERR_TOO_MANY = ERROR_PREFIX + ".Core.TooMany"
ERR_NOT_FOUND = ERROR_PREFIX + ".Core.NotFound"
ERR_RETRY = ERROR_PREFIX + ".Core.Retry"
ERR_TIMEOUT = ERROR_PREFIX + ".Core.Timeout"
ERR_ME_SIM_NOT_INSERTED = ERROR_PREFIX + ".MobileEquipment.SimNotInserted"
ERR_ME_SIM_PIN = ERROR_PREFIX + ".MobileEquipment.SimPin"
ERR_ME_SIM_PUK = ERROR_PREFIX + ".MobileEquipment.SimPuk"
ERR_ME_INCORRECT_PASSWORD = ERROR_PREFIX + ".MobileEquipment.IncorrectPassword"
ERR_ME_NO_NETWORK = ERROR_PREFIX + ".MobileEquipment.NoNetwork"
ERR_CONN_NO_CARRIER = ERROR_PREFIX + ".Connection.NoCarrier"

# Translations from the shannond core vocabulary ------------------------------

POWER_FROM_CORE = {"off": POWER_OFF, "lpm": POWER_LOW, "on": POWER_ON}

REG_FROM_CORE = {
    "idle": REG_IDLE,
    "home": REG_HOME,
    "searching": REG_SEARCHING,
    "denied": REG_DENIED,
    "unknown": REG_UNKNOWN,
    "roaming": REG_ROAMING,
}

ACCESS_FROM_RAT = {"gsm": ACCESS_GSM, "umts": ACCESS_UMTS, "lte": ACCESS_LTE}

CALL_STATE_FROM_CORE = {
    "dialing": CALL_DIALING,
    "alerting": CALL_RINGING_OUT,
    "active": CALL_ACTIVE,
    "held": CALL_HELD,
    "incoming": CALL_RINGING_IN,
    "waiting": CALL_WAITING,
    "released": CALL_TERMINATED,
}

CALL_DIRECTION_FROM_CORE = {"in": DIRECTION_INCOMING, "out": DIRECTION_OUTGOING}

# ip-type requested through MM -> word passed to core.data_connect()
IP_TYPE_TO_CORE = {
    IP_FAMILY_IPV4: "ipv4",
    IP_FAMILY_IPV6: "ipv6",
    IP_FAMILY_IPV4V6: "ipv4v6",
}

LOG_LEVELS = {"ERR": 40, "WARN": 30, "MSG": 25, "INFO": 20, "DEBUG": 10, "TRACE": 5}
