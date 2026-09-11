// Lifecycle of a single outbox row. Deliberately explicit rather than a Boolean
// "Sent" flag, because the drain loop needs to distinguish "never tried" from
// "tried and will try again" from "given up".
enum 50122 "PN Approval Outbox Status"
{
    Extensible = true;
    Caption = 'PN Approval Outbox Status';

    value(0; Pending) { Caption = 'Pending'; }        // written, never attempted
    value(1; Sending) { Caption = 'Sending'; }        // claimed by a runner right now
    value(2; Sent) { Caption = 'Sent'; }              // Azure Function returned 2xx
    value(3; Retrying) { Caption = 'Retrying'; }      // failed, Next Attempt At is in the future
    value(4; Failed) { Caption = 'Failed'; }          // max attempts burned, needs a human
    value(5; Skipped) { Caption = 'Skipped'; }        // superseded (e.g. already approved elsewhere)
}
