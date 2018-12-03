unit uMainForm;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Variants, System.Messaging, System.Permissions,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Objects, FMX.Controls.Presentation, System.Actions, FMX.ActnList,
  FMX.Edit, FMX.Media, ZXing.BarcodeFormat, ZXing.ReadResult, ZXing.ScanManager,
  FMX.Platform, FMX.Layouts, FMX.StdActns, FMX.MediaLibrary.Actions;

type
  TMainForm = class(TForm)
    ToolBar1: TToolBar;
    imgCamera: TImage;
    butStart: TButton;
    butStop: TButton;
    CameraComponent1: TCameraComponent;
    StyleBook1: TStyleBook;
    LayoutBottom: TLayout;
    lblScanStatus: TLabel;
    edtResult: TEdit;
    butShare: TButton;
    ActionList1: TActionList;
    ShowShareSheetAction1: TShowShareSheetAction;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure butStartClick(Sender: TObject);
    procedure butStopClick(Sender: TObject);
    procedure CameraComponent1SampleBufferReady(Sender: TObject;
      const ATime: TMediaTime);
    procedure edtResultChange(Sender: TObject);
    procedure ShowShareSheetAction1BeforeExecute(Sender: TObject);
  private
    { Private declarations }

    // for new Android security model
    FPermissionCamera, FPermissionReadExternalStorage,
      FPermissionWriteExternalStorage: string;

    // for the native zxing.delphi library
    fScanManager: TScanManager;
    fScanInProgress: Boolean;
    fFrameTake: Integer;
    procedure GetImage();
    function AppEvent(AAppEvent: TApplicationEvent; AContext: TObject): Boolean;

    // for new Android security model
    procedure DisplayRationale(Sender: TObject;
      const APermissions: TArray<string>; const APostRationaleProc: TProc);
    procedure TakePicturePermissionRequestResult(Sender: TObject;
      const APermissions: TArray<string>;
      const AGrantResults: TArray<TPermissionStatus>);
  public
    { Public declarations }
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}
{$R *.NmXhdpiPh.fmx ANDROID}

uses System.Threading,
{$IFDEF ANDROID}
  Androidapi.Helpers,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Os,
{$ENDIF}
  FMX.DialogService;

function TMainForm.AppEvent(AAppEvent: TApplicationEvent;
  AContext: TObject): Boolean;
begin
  Result := False;
  case AAppEvent of
    TApplicationEvent.WillBecomeInactive, TApplicationEvent.EnteredBackground,
      TApplicationEvent.WillTerminate:
      begin
        CameraComponent1.Active := False;
        Result := True;
      end;
  end;
end;

procedure TMainForm.butStartClick(Sender: TObject);
begin
  if Assigned(fScanManager) then
    fScanManager.Free;

  fScanManager := TScanManager.Create(TBarcodeFormat.Auto, nil);

  PermissionsService.RequestPermissions
    ([FPermissionCamera, FPermissionReadExternalStorage,
    FPermissionWriteExternalStorage], TakePicturePermissionRequestResult,
    DisplayRationale);

  lblScanStatus.Text := '';
  edtResult.Text := '';
end;

procedure TMainForm.butStopClick(Sender: TObject);
begin
  CameraComponent1.Active := False;
end;

procedure TMainForm.CameraComponent1SampleBufferReady(Sender: TObject;
  const ATime: TMediaTime);
begin
  TThread.Synchronize(TThread.CurrentThread, GetImage);
end;

procedure TMainForm.DisplayRationale(Sender: TObject;
  const APermissions: TArray<string>; const APostRationaleProc: TProc);
var
  I: Integer;
  RationaleMsg: string;
begin
  for I := 0 to High(APermissions) do
  begin
    if APermissions[I] = FPermissionCamera then
      RationaleMsg := RationaleMsg +
        'The app needs to access the camera to take a photo' + SLineBreak +
        SLineBreak
    else if APermissions[I] = FPermissionReadExternalStorage then
      RationaleMsg := RationaleMsg +
        'The app needs to read a photo file from your device';
  end;

  // Show an explanation to the user *asynchronously* - don't block this thread waiting for the user's response!
  // After the user sees the explanation, invoke the post-rationale routine to request the permissions
  TDialogService.ShowMessage(RationaleMsg,
    procedure(const AResult: TModalResult)
    begin
      APostRationaleProc;
    end)
end;

procedure TMainForm.edtResultChange(Sender: TObject);
begin
  ShowShareSheetAction1.Enabled := not edtResult.Text.IsEmpty;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  AppEventSvc: IFMXApplicationEventService;
begin
{$IFDEF ANDROID}
  FPermissionCamera := JStringToString(TJManifest_permission.JavaClass.CAMERA);
  FPermissionReadExternalStorage :=
    JStringToString(TJManifest_permission.JavaClass.READ_EXTERNAL_STORAGE);
  FPermissionWriteExternalStorage :=
    JStringToString(TJManifest_permission.JavaClass.WRITE_EXTERNAL_STORAGE);
{$ENDIF}
  if TPlatformServices.Current.SupportsPlatformService
    (IFMXApplicationEventService, IInterface(AppEventSvc)) then
  begin
    AppEventSvc.SetApplicationEventHandler(AppEvent);
  end;

  fFrameTake := 0;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  fScanManager.Free;
end;

procedure TMainForm.GetImage;
var
  scanBitmap: TBitmap;
  ReadResult: TReadResult;

begin
  CameraComponent1.SampleBufferToBitmap(imgCamera.Bitmap, True);

  if (fScanInProgress) then
  begin
    exit;
  end;

  { This code will take every 2 frame. }
  inc(fFrameTake);
  if (fFrameTake mod 2 <> 0) then
  begin
    exit;
  end;

  scanBitmap := TBitmap.Create();
  scanBitmap.Assign(imgCamera.Bitmap);
  ReadResult := nil;

  TTask.Run(
    procedure
    begin
      try
        fScanInProgress := True;
        try
          ReadResult := fScanManager.Scan(scanBitmap);
        except
          on E: Exception do
          begin
            TThread.Synchronize(nil,
              procedure
              begin
                lblScanStatus.Text := E.Message;
              end);

            exit;
          end;
        end;

        TThread.Synchronize(nil,
          procedure
          begin

            if (length(lblScanStatus.Text) > 10) then
            begin
              lblScanStatus.Text := '*';
            end;

            lblScanStatus.Text := lblScanStatus.Text + '*';

            if (ReadResult <> nil) then
            begin
              edtResult.Text := ReadResult.Text;
            end;

          end);

      finally
        ReadResult.Free;
        scanBitmap.Free;
        fScanInProgress := False;
      end;

    end);
end;

procedure TMainForm.ShowShareSheetAction1BeforeExecute(Sender: TObject);
begin
  ShowShareSheetAction1.TextMessage := edtResult.Text;
end;

procedure TMainForm.TakePicturePermissionRequestResult(Sender: TObject;
const APermissions: TArray<string>;
const AGrantResults: TArray<TPermissionStatus>);
begin
  // 3 permissions involved: CAMERA, READ_EXTERNAL_STORAGE and WRITE_EXTERNAL_STORAGE
  if (length(AGrantResults) = 3) and
    (AGrantResults[0] = TPermissionStatus.Granted) and
    (AGrantResults[1] = TPermissionStatus.Granted) and
    (AGrantResults[2] = TPermissionStatus.Granted) then
  begin
    CameraComponent1.Quality := FMX.Media.TVideoCaptureQuality.MediumQuality;
    CameraComponent1.Active := False;
    CameraComponent1.Kind := FMX.Media.TCameraKind.BackCamera;
    CameraComponent1.FocusMode := FMX.Media.TFocusMode.ContinuousAutoFocus;
    CameraComponent1.Active := True;
  end
  else
  begin
    TDialogService.ShowMessage
      ('Cannot take a photo because the required permissions are not all granted');
  end;
end;

end.
