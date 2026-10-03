// C interface of OpenMTP's Kalam MTP kernel (github.com/ganeshrvel/openmtp, MIT).
// Every call is synchronous: callbacks fire on the calling thread before it returns,
// each with a JSON envelope {"errorType": "", "error": "", "data": ...}.
// The cgo header declares the callbacks as `on_cb_result_t *`, but Kalam invokes the
// pointer directly, so they are plain function pointers here.

typedef void (*kalam_cb)(char *json);

void Initialize(kalam_cb onDone);
void FetchDeviceInfo(kalam_cb onDone);
void FetchStorages(kalam_cb onDone);
void MakeDirectory(char *json, kalam_cb onDone);
void FileExists(char *json, kalam_cb onDone);
void DeleteFile(char *json, kalam_cb onDone);
void RenameFile(char *json, kalam_cb onDone);
void Walk(char *json, kalam_cb onDone);
void UploadFiles(char *json, kalam_cb onPreprocess, kalam_cb onProgress, kalam_cb onDone);
void DownloadFiles(char *json, kalam_cb onPreprocess, kalam_cb onProgress, kalam_cb onDone);
void Dispose(kalam_cb onDone);
