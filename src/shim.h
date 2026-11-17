// C interfaces the Swift side needs that Foundation does not re-export.

// clonefile(2): APFS copy-on-write clone of the whole app bundle. Cloning Conductor takes
// a few milliseconds and costs no disk until something is written.
#include <sys/clonefile.h>

// proc_listpids / proc_pidpath: used to tell whether anything is still executing out of
// the ephemeral bundle. Conductor's updater relaunches the app, so "the process we
// launched exited" is not the same question as "the bundle is free to delete".
#include <libproc.h>
