// What happened to the Approval Entry. The Azure Function branches on this:
// "Requested" produces a card, everything else updates or retires an existing one.
enum 50121 "PN Approval Event Type"
{
    Extensible = true;
    Caption = 'PN Approval Event Type';

    value(0; Requested) { Caption = 'Approval Requested'; }
    value(1; Approved) { Caption = 'Approved'; }
    value(2; Rejected) { Caption = 'Rejected'; }
    value(3; Cancelled) { Caption = 'Cancelled'; }
    value(4; Delegated) { Caption = 'Delegated'; }
}
