%% BFPGUI: Function running the BFPClass GUI
%   Manages the analysis of a BFP experiment recording. Takes inputs from
%   the user and calls appropriate computational methods to track and
%   calculate forces. It performs many maintainance tasks (e.g. basic
%   fitting, measurements, fine-tuning of the detection), and import-export
%   tools.
%   *OUT:*
%   backdoorObj: is a handle superclass object, which is connected to some of
%   the important parameters within the BFPClass and BFPGUI. It allows user
%   to change these parameters from the Matlab command line. It is usually
%   not necessary to access these paremeters.
%   *IN:*
%   loadData (Optional): allows user to start GUI instance with data 
%   imported from an older MAT file form earlier session or another machine
%   ======================================================================

function [ backdoorObj ] = BFPGUI( varargin )
%% Add help path into Matlab path
    [apppath,~,~] = fileparts(mfilename('fullpath')); % path to the current M-file (BFPGUI.m)
    apphtmls = numel(strfind(apppath,'html'));    % find possible html strings in app path (would usually be 0)
    allpath=genpath(apppath);   % get all the subfolders below BFPGUI folder (avoid direct path manipulation because of platform problems)
    while(allpath)
        [helpstr,allpath]= strtok(allpath,':'); % tokenize all subfolders
        fphtml = strfind(helpstr,'html');       % find positions of htmls in the full path 
        fphtmls = numel(fphtml);    % number of htmls in the full path
        if fphtmls-apphtmls > 0;    % a html exist after app path
            helpstr = helpstr(1:fphtml(apphtmls+1)+3);    % cut the string after the first html subfolder
            break;  % stop when outer 'html' folder is found
        end;
        helpstr=[]; % delete string if nothing found
    end
    if ~isempty(helpstr)
        addpath(helpstr);  % add path to html folder
    end

%% Importing data
    % verify if passed input is a MAT file
    function [is] = isMatFile(file)
        is = false;
        if exist(file,'file')
            [~,~,ext] = fileparts(file);
            if strcmp(ext,'.mat'); is = true; end;
        end;
    end

    inpMain = inputParser();
    noLoad = false;
    
    addOptional(inpMain,'loadData', noLoad, @isMatFile)
    
    inpMain.parse(varargin{:});
    
    loadData = inpMain.Results.loadData;
    
% ===================================================================

%% UI settings
handles.verbose = true;     % sets UI to provide more (true) or less (false) messages
handles.selecting = false;  % indicates, if selection is under way and blocks other callbacks of selection
handles.fitfontsize = 0.07; % normalized size of the font in equations
handles.labelfontsize = 0.04;   % normalized size of the font in (some) labels
% handles.verbose is a switch for a 'warn' method. It decides whether some of the
% warnings appear as warning dialogues, or just command line warnings

% create backdoor object to modify hidden parameters
backdoorObj = BFPGUIbackdoor(@backdoorFunction);

% turn off LibTIFF warnings
warning('off','MATLAB:imagesci:tiffmexutils:libtiffWarning');

% constants
RBC = 2.5;
PIP = 1;
CON = 0.75;

%% Variables related to tracking
handles.pattern = [];       % pattern to be tracked over the video; an image
handles.lastlistpat = [];   % the last pattern chosen for the list
handles.patternlist = [];   % list of selected patterns
handles.bead = [];          % coordinates of bead to be tracked over the video
handles.lastlistbead = [];  % the last bead chosen for the list
handles.beadlist = [];      % the list of inicial coordinates of beads for tracking
handles.beadradius = [8,18];    % limits on radius of the bead
handles.beadbuffer = 5;         % limit on grace period if bead cannot be detected (in frames)
handles.pipbuffer = 5;          % limit on grace period if pipette pattern can't be detected (in frames)
handles.beadsensitivity = 0.8;  % circle finding method sensitivity
handles.beadgradient = 0.2;     % circle finding method gradient threshold
handles.beadmetricthresh = 0.8; % circle finding method metric threshold
handles.pipmetricthresh = 0.95; % pipette tracking correlation threshold
handles.contrasthresh = 0.95;   % contrast quality threshold
handles.overLimit = false;      % indicates if currently calculated force is within linear approx. limit of not

%% Variables related to video file
vidObj = [];        % video wrapper, to open videos (AVI,MP4,...) and TIFF alike
handles.videopath = pwd;    % path to the video file
handles.vidFrameNo = 0;     % number of the currently displayed frame
handles.frame = [];         % the currently displayed frame
handles.playing = true;     % video is allowed to play
handles.disptrack = false;  % display track marks on the video
handles.outframerate = 10;  % framerate of the output video
handles.outsampling = 1;    % each n-th frame of original video is taken for output

%% Experimental parameters
handles.pressure = 200;     % aspirating pressure of the pipette
handles.RBCradius = RBC;    % radius of RBC
handles.PIPradius = PIP;    % inner pipette radius
handles.CAradius = CON;     % radius of contact between streptabead and RBC
handles.P2M = 0.1024;       % pixels to microns coefficient
handles.stiffness = 200;    % RBC stiffness, in pN/micron

%% Tracking data structures
intfields = { 'pattern', 'patcoor', 'beadcoor', 'patsubcoor', 'contrast','reference','frames' };
colnames = {'Range|Start', 'Range|End', 'Bead|X-coor', 'Bead|Y-coor', 'Pipette|X-coor', 'Pipette|Y-coor', 'Anchor|X-coor', 'Anchor|Y-coor', 'Remove'};
colformat = {'numeric', 'numeric','numeric', 'numeric','numeric', 'numeric','numeric', 'numeric','logical'};
axesposition = [0.05,0.05,0.5,0.5];
handles.tmpbeadframe = [];  % stores value of current bead frame selected for the interval
handles.tmppatframe = [];   % ... and the same for the pipette pattern
handles.interval = struct('frames', [1,1],'pattern',[]); % currently assembled interval (not in the list yet)
handles.intervallist = [];  % list of tracking intervals with settings
BFPobj = [];                % BFPClass object containing the calculation/tracking
handles.remove = [];        % list of interval entries to remove from the complete list
handles.updpatframe = 0;    % pipette pattern originating frame, updated during addition process
handles.calibint = [];      % single-frame interval in case a calibration frame needs to be set up

%% Plotting and fitting settings variables
handles.lowplot     = 1;    % lower bound of plotted data
handles.highplot    = 10;   % upper bound of plotted data
handles.toPlot      = 1;    % quantity to be plotted (1=contrast, 2=track (3D), 3=trajectories (2D), 4=force, 5=metrics)
handles.thisPlot    = [];   % quantity currently displayed in the handles.hgraph (+6=outer graph)
handles.thisRange   = [];   % current range of frames of the plot
handles.fitInt      = [];   % interval of data to which apply the fitting procedure
handles.kernelWidth = 5;    % width of the differentiating kernel in plateau detection
handles.noiseThresh = sqrt(2);  % multiple of derivative's std to be considered noise (pleatea)
handles.minLength   = 30;   % minimal number of frames to constitute a plateau
handles.hzeroline = [];     % handle of a line representing a zero force
handles.pushtxt   = [];     % texthandle for a pushing region descriptor ...
handles.pulltxt   = [];     % ... and the like for pulling region
handles.contype   = 1;      % type of contrast metric to display (1=SD2, 2=rSD2; see documentation)
handles.calibrated= false;  % flags if the calculated force is calibrated (before force calculation if always false)

%% Lists of UI handles for export/import; mutable handles
GUIflags.Strings = {'hvideopath', 'hdispframe', 'hfrmrate', 'hsampling', ...
            'hpatternlist', 'hpatcoortxt', 'hbeadinilist', 'hbeadcoortxt',...
            'hcorrthreshtxt', 'hcontrasthreshtxt', 'hpipbuffer',...
            'hminrad', 'hmaxrad', 'hbuffer', 'hsensitivitytxt', ...
            'hgradtxt', 'hmetrictxt','hstartint','hendint', 'hrefframe',...
            'hpatternint','hbeadint', 'hpatsubcoor','hpressure','hRBCrad',...
            'hPIPrad','hCArad','hP2M', 'hvidheight', 'hvidwidth',...
            'hvidduration','hvidframes','hvidframerate','hvidname','hvidformat',...
            'hlowplot','hhighplot','hgetplatwidth','hplatwidth','hgetplatthresh','hplatthresh',...
            'hgetplatmin','hplatmin','hfitint', };
        
GUIflags.Values = {'hmoviebar', 'hpatternlist', 'hcorrthresh','hcontrasthresh', 'hbeadinilist',...
            'hsensitivitybar', 'hgradbar', 'hmetric','hgraphbead','hgraphpip','hverbose','hhideexp',...
            'hhidelist','hhidedet', 'hdisptrack', 'hgraphitem', 'hSD2', 'hrSD2'};

GUIflags.Enables = {'hmoviebar', 'hplaybutton', 'hrewindbtn', 'hffwdbutton', ...
            'hcontrast', 'hgenfilm', 'hstartint', 'hshowframe', 'hendint', 'hrefframe',...
            'hgetrefframe', 'hshowpattern','hgetpattern', 'hselectpat', 'hgetbead',...
            'hselectbead', 'hgetpatsubcoor', 'haddinterval', 'heraseint',...
            'hupdate','hruntrack','hrunforce','hgraphplot','hgraphitem','hgraphbead',...
            'hgraphpip','hlowplot','hhighplot','hreport','hlinearinfo','hfitline',...
            'hfitexp','hfitplateau','hplatwidth','hplatthresh','hplatmin','hexport',...
            'himport'};

GUIflags.Visibles = {'hpatterns', 'hbeadmethods', 'hpipdetection','hbeaddetection',...
            'hexpdata','hgetplatwidth','hgetplatthresh','hgetplatmin'};
        
%% List of GUI variables, mutables
GUIdata = {'verbose', 'selecting', 'fitfontsize', 'labelfontsize', 'pattern', ...
            'lastlistpat', 'patternlist', 'bead', 'lastlistbead', 'beadlist', ...
            'beadradius', 'beadbuffer', 'pipbuffer', 'beadsensitivity',...
            'beadgradient', 'beadmetricthresh', 'pipmetricthresh', 'contrasthresh',...
            'overLimit', 'videopath', 'vidFrameNo', 'frame', 'playing',...
            'disptrack', 'outframerate', 'outsampling', 'pressure', 'RBCradius',...
            'PIPradius', 'CAradius', 'P2M', 'stiffness', 'tmpbeadframe',...
            'tmppatframe', 'interval', 'intervallist', 'remove', 'updpatframe',...
            'calibint', 'lowplot', 'highplot', 'toPlot', 'thisPlot', 'thisRange',...
            'fitInt', 'kernelWidth', 'noiseThresh', 'minLength', 'hzeroline',...
            'pushtxt', 'pulltxt', 'contype', 'calibrated' };
        
        
%% ================= SETTING UP GUI CONTROLS =========================
% contans parameters for the figure, movie axes, graphing axes and film bar
handles.hfig = figure('Name', 'Pattern tracking','Units', 'normalized', 'OuterPosition', [0,0,1,1], ...
             'Visible', 'on', 'Selected', 'on','WindowScrollWheelFcn',{@mouseplay_callback});
handles.haxes = axes('Parent',handles.hfig,'Units', 'normalized', 'Position', axesposition,...
             'Visible', 'on','FontUnits','normalized');
handles.hgraph = axes('Parent',handles.hfig,'Units','normalized', 'Position', [0.6,0.6,0.35,0.35],...
             'ButtonDownFcn',{@getcursor_callback},'FontUnits','normalized');
handles.hmoviebar = uicontrol('Parent',handles.hfig, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', 0, ...
             'Units', 'normalized', 'Enable', 'off',...
             'SliderStep', [0.01, 1], 'Position', [0.05, 0.005, 0.5, 0.015],...
             'Callback', {@videoslider_callback});
% =================================================================== 

%% ================= OPENNING A VIDEO FILE ===========================
% set panel to open, browse and input video path
handles.hopenvideo = uibuttongroup('Parent', handles.hfig, 'Title','Open a video', 'Position', [0.05, 0.56, 0.25, 0.075]);
handles.hvideopath = uicontrol('Parent',handles.hopenvideo, 'Style', 'edit', ...
            'Units', 'normalized',...
            'String', handles.videopath, 'Position', [0, 0.5, 1, 0.5],...
            'Enable', 'on','Callback',{@videopath_callback});
handles.hvideobutton = uicontrol('Parent',handles.hopenvideo,'Style','pushbutton',...
             'Units', 'normalized', 'Position', [0,0,0.2,0.5], ...
             'String', 'Open', 'Callback',{@openvideo_callback});
handles.hvideobrowse = uicontrol('Parent',handles.hopenvideo,'Style','pushbutton',...
             'Units', 'normalized', 'Position', [0.2,0,0.2,0.5], ...
             'String', 'Browse', 'Callback',{@browsevideo_callback});
set([handles.hvideobutton,handles.hvideobrowse,handles.hvideopath],'FontUnits','normalized');         
% ====================================================================    

%% ================= WORKING WITH THE VIDEO ===========================
% video control buttons like, Play, Stop, FFW, RWD, analyze contrast, go to
% frame, generate film, sampling, output framerate etc.
handles.husevideo   = uibuttongroup('Parent', handles.hfig, 'Title', 'Video commands', 'Units', 'normalized',...
             'Position', [0.31, 0.56, 0.24, 0.1]);
handles.hplaybutton = uicontrol('Parent', handles.husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0.2,0.5,0.2,0.5],'FontUnits','normalized',...
             'String', 'Play','Interruptible','on', 'Callback', {@playvideo_callback,1});
handles.hrewindbtn  = uicontrol('Parent', handles.husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0,0.5,0.2,0.5],'FontUnits','normalized',...
             'String', 'Rewind','Interruptible','on', 'Callback', {@fastvideo_callback,-5});
handles.hffwdbutton = uicontrol('Parent', handles.husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0.4,0.5,0.2,0.5],'FontUnits','normalized',...
             'String', '<HTML><center>Fast<br>forward</HTML>','Interruptible','on', 'Callback', {@fastvideo_callback,5});           
              uicontrol('Parent',handles.husevideo, 'Style','text', 'Units', 'normalized','FontUnits','normalized',...
             'Position', [0.6, 0.75, 0.2, 0.25],'String','Frame: ','HorizontalAlignment','left');     
handles.hcontrast  = uicontrol('Parent',handles.husevideo, 'Style','pushbutton','Units', 'normalized',...
             'String', '<HTML><center>Analyse<br>contrast</HTML>', 'Position', [0,0,0.2,0.5],'FontUnits','normalized','Callback',{@getcontrast_callback,'analysis'},...
             'TooltipString', 'Calculates contrast measure curve. Useful if splitting video into intervals.');
handles.hdispframe = uicontrol('Parent',handles.husevideo, 'Style','pushbutton', 'Units', 'normalized','FontUnits','normalized',...
             'Position', [0.8, 0.75, 0.2, 0.25],'String','0/0','Callback',@gotoframe_callback,...
             'Enable','off');
handles.hdisptrack = uicontrol('Parent', handles.husevideo, 'Style', 'checkbox', 'Units', 'normalized',...
             'String', 'Display track info', 'Position', [0.6, 0.5, 0.4, 0.25],...
             'HorizontalAlignment','left','TooltipString','Displays tracking results on top of the video',...
             'Value', handles.disptrack, 'Callback', {@disptrack_callback});
handles.hgenfilm   = uicontrol('Parent', handles.husevideo', 'Style', 'pushbutton', 'Units', 'normalized', ...
             'String',{'<HTML><center>Generate<br>film'}, 'Position', [0.2,0,0.2,0.5], 'FontUnits','normalized','Callback', {@generatefilm_callback},...
             'TooltipString','Generates a video file as an overlay of the open video and tracking marks');
handles.hframeratetxt = uicontrol('Parent', handles.husevideo, 'Style', 'text','Units','normalized', ...
             'String','Framerate:','Position',[0.4,0.25,0.2,0.25],'HorizontalAlignment', 'left');
handles.hsamplingtxt  = uicontrol('Parent', handles.husevideo, 'Style', 'text','Units','normalized',...
             'String','Sampling:','Position',[0.4,0,0.2,0.25],'HorizontalAlignment', 'left',...
             'TooltipString','<HTML>The number signifies each n-th frame of the original video to be processed.<br>Note that processing long videos can be time demanding.</HTML>');
handles.hfrmrate    = uicontrol('Parent',handles.husevideo,'Style','edit','Units','normalized',...
             'String',num2str(10),'Position', [0.6,0.25,0.2,0.25],'Callback',{@outvideo_callback,10,1});
handles.hsampling   = uicontrol('Parent',handles.husevideo,'Style','edit','Units','normalized',...
             'String',num2str(1),'Position',[0.6,0,0.2,0.25],'Callback',{@outvideo_callback,1,2});
set([handles.hplaybutton,handles.hrewindbtn,handles.hffwdbutton,handles.hcontrast,handles.hgenfilm],'Enable','off');     
set([handles.hdisptrack,handles.hframeratetxt,handles.hsamplingtxt,handles.hfrmrate,handles.hsampling], 'FontUnits','normalized');
% ====================================================================

%% ================= PATTERN COLLECTION ===============================
% set pipette tip pattern, create pattern list, add and remove from the
% list, miniaxes to display a pattern, diplay pattern info
handles.hpatterns = uibuttongroup('Parent', handles.hfig, 'Title', 'Pipette patterns', 'Units', 'normalized',...
            'Position', [0.56, 0.29, 0.1, 0.26],'Visible','off');
handles.hpatternlist = uicontrol('Parent', handles.hpatterns, 'Style', 'popup', 'String', {'no data'}, 'Value', 1, ...
            'Units', 'normalized', 'Position', [0,0.8,1, 0.2], 'FontUnits','normalized','Callback', {@pickpattern_callback});
handles.haddpatternbtn = uicontrol('Parent', handles.hpatterns, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0,0.5,0.5,0.15], 'String', 'Add', 'Callback', {@addpattern_callback});
handles.hrmpatternbtn = uicontrol('Parent', handles.hpatterns, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0.5,0.5,0.5,0.15],'String', 'Remove', 'Callback', {@rmpattern_callback});      
handles.hrectbutton = uicontrol('Parent',handles.hpatterns,'Style','pushbutton',...
             'Units', 'normalized', 'Interruptible', 'off','BusyAction','cancel',...
             'Position', [0,0.65,0.5,0.15], 'String', 'Select', 'Callback',{@getrect_callback,'list'});
handles.hpatcoortxt = uicontrol('Parent', handles.hpatterns, 'Style', 'text' , 'String', {'[.,.;,]'},...
            'Units', 'normalized', 'Position', [0.5,0.65,0.5,0.15],'FontUnits','normalized');
handles.hminiaxes = axes('Parent',handles.hpatterns, 'Units', 'normalized', 'Position', [0.05, 0.05, 0.9, 0.44],'FontUnits','normalized',...
             'Visible', 'on', 'XTickLabel', '', 'YTicklabel', '' );
align(handles.hpatcoortxt,'Left','Middle');
set([handles.haddpatternbtn,handles.hrmpatternbtn,handles.hrectbutton],'FontUnits','normalized');
% ====================================================================

%% ================= BEAD DETECTION METHODS ===========================
% set bead detection methods, create bead list, select ini. coordinate,
% add and remove items from the list
handles.hbeadmethods = uipanel('Parent', handles.hfig, 'Title', 'Bead tracking', 'Units', 'normalized',...
            'Position', [0.56, 0.05, 0.1, 0.24],'Visible','off');
handles.hbeadinilist = uicontrol('Parent', handles.hbeadmethods, 'Style', 'popup', 'String', {'no data'},'Value',1,...
            'Units', 'normalized', 'Position', [0,0.3,1, 0.25],'FontUnits','normalized', 'Callback', {@pickbead_callback});
handles.hpointbtn = uicontrol('Parent', handles.hbeadmethods, 'Style', 'pushbutton', 'Units', 'normalized',...
            'Position', [0,0.15,0.5,0.15], 'Interruptible', 'off','BusyAction','cancel', ...
            'String', 'Select', 'Callback', {@getpoint_callback, 'list'});
handles.hbeadcoortxt = uicontrol('Parent', handles.hbeadmethods, 'Style', 'text' , 'String', {'[.,.;,]'},...
            'Units', 'normalized', 'Position', [0.5,0.15,0.5,0.15],'FontUnits','normalized');
handles.haddbeadbtn = uicontrol('Parent', handles.hbeadmethods, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0,0,0.5,0.15], 'String', 'Add', 'Callback', {@addbead_callback});
handles.hrmbeadbtn = uicontrol('Parent', handles.hbeadmethods, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0.5,0,0.5,0.15],'String', 'Remove', 'Callback', {@rmbead_callback});  
set([handles.hpointbtn,handles.haddbeadbtn,handles.hrmbeadbtn], 'FontUnits','normalized');        
% ====================================================================

%% ================= PIPETTE DETECTION SETTINGS =======================
% set pipette detection, correlation and contrast thresholds, failed frame
% buffer
handles.hpipdetection   = uibuttongroup('Parent', handles.hfig, 'Title', 'Pipette detection settings', 'Units', 'normalized',...
            'Position', [0.66, 0.29, 0.1, 0.26],'Visible','off');   
handles.hcorrthreshtxt  = uicontrol('Parent',handles.hpipdetection, 'Style', 'text', 'String', {'Correlation'; strjoin({'thresh:', num2str(handles.pipmetricthresh)})},...
            'TooltipString', 'Lower limit on cross correlation matching', 'Units','normalized',...
            'Position', [0,0.85,0.5,0.15],'FontUnits','normalized');
handles.hcorrthresh     = uicontrol('Parent',handles.hpipdetection,'Style','slider','Max',1,'Min',0,'Value',handles.pipmetricthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.01,0.1],'Position',[0.5,0.85,0.5,0.15],...
             'Callback',{@pipmetric_callback});
handles.hcontrasthreshtxt = uicontrol('Parent',handles.hpipdetection, 'Style', 'text', 'String', {'Contrast'; strjoin({'thresh:', num2str(handles.contrasthresh)})},...
            'TooltipString', 'Lower limit on contrast decrease', 'Units', 'normalized',...
            'Position', [0,0.7,0.5,0.15],'FontUnits','normalized');
handles.hcontrasthresh  = uicontrol('Parent',handles.hpipdetection,'Style','slider','Max',1,'Min',0,'Value',handles.contrasthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.01,0.1],'Position',[0.5,0.7,0.5,0.15],...
             'Callback',{@pipcontrast_callback});       
handles.hpipbufftxt     = uicontrol('Parent',handles.hpipdetection, 'Style', 'text', 'String', 'Buffer frames',...
            'TooltipString', 'Number of consecutive frames of failed detection, allowing procedure to try to recover',...
            'Units','normalized','Position', [0,0.55,0.5,0.1]);        
handles.hpipbuffer      = uicontrol('Parent',handles.hpipdetection', 'Style', 'edit', 'String', num2str(handles.pipbuffer),...
            'Units','normalized','Position',[0.5,0.55,0.5,0.15],'Callback',{@pipbuffer_callback});   
set([handles.hpipbufftxt,handles.hpipbuffer],'FontUnits','normalized');        
% ====================================================================

%% ================= BEAD DETECTION SETTINGS ==========================
% set pipette detection, radius range, edge and metric sensitivity, failed
% frame buffer, metric threshold
handles.hbeaddetection = uibuttongroup('Parent', handles.hfig, 'Title', 'Bead detection settings', 'Units', 'normalized',...
            'Position', [0.66, 0.05, 0.1, 0.24],'Visible','off');
handles.hradtxt     = uicontrol('Parent', handles.hbeaddetection, 'Style', 'pushbutton', 'String','<HTML><center>Radius range</HTML>',...
            'Units', 'normalized','Position', [0,0.85,0.5,0.15],'Callback',{@getradrange_callback,'beadrad'},'Enable','off');
handles.hminrad     = uicontrol('Parent', handles.hbeaddetection, 'Style', 'edit', 'String', num2str(handles.beadradius(1)),...
            'Units', 'normalized','Position', [0.5,0.85,0.2,0.15],'Callback', {@setrad_callback});
handles.hmaxrad     = uicontrol('Parent', handles.hbeaddetection, 'Style', 'edit', 'String', num2str(handles.beadradius(2)),...
            'Units', 'normalized','Position', [0.75,0.85,0.2,0.15],'Callback', {@setrad_callback});
handles.hbuffertxt  = uicontrol('Parent', handles.hbeaddetection, 'Style', 'text', 'String', 'Buffer frames',...
                    'TooltipString', 'Number of frames allowed to pass without successful bead detection',...
                    'Units', 'normalized','Position', [0,0.7,0.5,0.1]);
handles.hbuffer = uicontrol('Parent', handles.hbeaddetection, 'Style', 'edit', 'String', num2str(handles.beadbuffer),...
            'Units', 'normalized','Position', [0.5,0.7,0.2,0.15],'Callback', {@setbuffer_callback});
handles.hsensitivitytxt = uicontrol('Parent', handles.hbeaddetection, 'Style', 'text', 'String', {'Sensitivity: ';num2str(round(handles.beadsensitivity,2))},...
                    'TooltipString', 'Higher sensitivity detects more circular objects, including weak and obscured',...
                    'Units', 'normalized','Position', [0,0.55,0.5,0.15]);
handles.hsensitivitybar = uicontrol('Parent',handles.hbeaddetection, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', handles.beadsensitivity, ...
             'Units', 'normalized', 'Enable', 'on',...
             'SliderStep', [0.01, 0.1], 'Position', [0.5, 0.55, 0.5, 0.15],...
             'Callback', {@beadsensitivity_callback});
handles.hgradbar = uicontrol('Parent',handles.hbeaddetection, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', handles.beadgradient, ...
             'Units', 'normalized', 'Enable', 'on',...
             'SliderStep', [0.01, 0.1], 'Position', [0.5, 0.4, 0.5, 0.15],...
             'Callback', {@beadgrad_callback});
handles.hgradtxt = uicontrol('Parent', handles.hbeaddetection, 'Style', 'text', 'String', {'Gradient: ';num2str(round(handles.beadgradient,2))},...
             'TooltipString', 'Lower gradient threshold detects more circular objects, including weak and obscured',...
             'Units', 'normalized','Position', [0,0.4,0.5,0.15]);
handles.hmetrictxt  = uicontrol('Parent',handles.hbeaddetection,'Style','text','String',{'Metric';strjoin({'thresh:',num2str(handles.beadmetricthresh)})},...
             'TooltipString', 'Lower threshold gives more credibility to less certain findings',...
             'Units','normalized','Position',[0,0.25,0.5,0.15]);
handles.hmetric     = uicontrol('Parent',handles.hbeaddetection,'Style','slider','Max',2,'Min',0,'Value',handles.beadmetricthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.005,0.1],'Position',[0.5,0.25,0.5,0.15],...
             'Callback',{@beadmetric_callback});
set([handles.hradtxt,handles.hminrad,handles.hmaxrad,handles.hbuffertxt, handles.hbuffer,handles.hsensitivitytxt,handles.hgradtxt,handles.hmetrictxt,handles.hmetric],'FontUnits','normalized');         
% ====================================================================

%% ==================== SELECTING INTERVALS TO TRACK ==================
% major part of the UI, set the chain of intervals to track, input interval
% of frames, initial bead position (from list or pick in frame), pipette
% pattern (from list of pick in frame), show pattern, select anchor point
% on the pattern, detect reference frame, add to interval
handles.hintervals  = uitabgroup('Parent', handles.hfig, 'Units','normalized', 'Position', [0.05, 0.635, 0.25, 0.225]);
handles.hsetinterval  = uitab('Parent', handles.hintervals, 'Title', 'Set interval', 'Units', 'normalized');
handles.hintervaltxt= uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', 'Interval:', ...
                      'TooltipString', 'Interval of interest for tracking, in frames',...
                      'Units','normalized','Position', [0,0.75,0.25,0.25],'HorizontalAlignment','left' );
handles.hstartint   = uicontrol('Parent', handles.hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.25,0.75,0.15,0.25],'Callback',{@setintrange_callback,1,1});
handles.hshowframe  = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'Show', ...
                      'Units','normalized','Position', [0.4,0.75,0.1,0.25],'Enable','off',...
                      'Callback',{@gotointframe_callback});                  
handles.hendint     = uicontrol('Parent', handles.hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.5,0.75,0.25,0.25],'Callback',{@setintrange_callback,1,2});
handles.hrefframe  = uicontrol('Parent',handles.hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.75,0.75,0.15,0.25],...
                      'Callback',{@setrefframe_callback,0});
handles.hgetrefframe = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', {'Get';'current'}, ...
                      'Units','normalized','Position', [0.9,0.75,0.1,0.25],'Enable','off',...
                      'TooltipString', 'Searches pattern''s reference frame in previous records',...
                      'Callback', {@getrefframe_callback});                  
handles.hpatterntxt  = uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', 'Selected pattern:', ...
                      'TooltipString', 'Pattern to be tracked over the interval',...
                      'Units','normalized','Position', [0,0.5,0.25,0.25],'HorizontalAlignment','left' );
handles.hpatternint  = uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', '[.,.;.]', ...
                      'TooltipString', 'Coordinates of the selected pattern',...
                      'Units','normalized','Position', [0.25,0.5,0.25,0.25],'HorizontalAlignment','center' );                  
handles.hshowpattern = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'Show', ...
                      'Units','normalized','Position', [0.75,0.5,0.25,0.25],'Enable','off',...
                      'Callback',{@showintpattern_callback});
handles.hgetpattern  = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'List', ...
                      'Units','normalized','Position', [0.5,0.5,0.125,0.25],...
                      'Enable','off','Callback',{@getintpat_callback});
handles.hselectpat   = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'Select', ...
                      'Units','normalized','Position', [0.625,0.5,0.125,0.25],...
                      'Enable','off','Callback',{@getrect_callback,'interval'});                  
handles.hbeadtxt     = uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', 'Selected bead:', ...
                      'TooltipString', 'Bead to be tracked over the interval',...
                      'Units','normalized','HorizontalAlignment','left','Position', [0,0.25,0.25,0.25] );                  
handles.hbeadint     = uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', '[.,.;.]', ...
                      'TooltipString', 'Coordinates of the selected bead',...
                      'Units','normalized','Position', [0.25,0.25,0.25,0.25],'HorizontalAlignment','center' );                  
handles.hgetbead     = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'List', ...
                      'Units','normalized','Position', [0.5,0.25,0.125,0.25],...
                      'Enable','off','Callback',{@getintbead_callback});
handles.hselectbead  = uicontrol('Parent',handles.hsetinterval, 'Style', 'pushbutton', 'String', 'Select', ...
                      'Units','normalized','Position', [0.625,0.25,0.125,0.25],...
                      'Enable','off','Callback',{@getpoint_callback,'interval'});                  
handles.hpatanchortxt= uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', 'Pattern anchor:', ...
                      'TooltipString', 'Precise point on the pattern, whose position in time should be reported',...
                      'Units','normalized','Position', [0,0,0.25,0.25],'HorizontalAlignment','left' );
handles.hpatsubcoor  = uicontrol('Parent',handles.hsetinterval, 'Style', 'text', 'String', '[.,.]', ...
                      'TooltipString', 'Precise point on the pattern to be tracked',...
                      'Units','normalized','Position', [0.25,0,0.25,0.25],'HorizontalAlignment','center');
handles.hgetpatsubcoor = uicontrol('Parent',handles.hsetinterval, 'Style','pushbutton', 'String', 'Select',...
                      'Units','normalized','Position', [0.5,0,0.25,0.25], 'Enable','off',...
                      'Callback', {@getpatsubcoor_callback});
handles.haddinterval = uicontrol('Parent',handles.hsetinterval, 'Style','pushbutton','String',{'Add to list'},...
                      'Units','normalized','Position', [0.75,0,0.25,0.5],...
                      'Enable','off','Callback',{@addinterval_callback});
set([handles.hshowframe,handles.hrefframe,handles.hgetrefframe,...
    handles.hshowpattern, handles.hgetpattern, handles.hselectpat, handles.hgetbead,...
    handles.hselectbead, handles.hgetpatsubcoor, handles.haddinterval], 'FontUnits','normalized');
set([handles.hintervaltxt, handles.hpatterntxt, handles.hpatanchortxt, handles.hbeadtxt,handles.hstartint,...
    handles.hendint,handles.hbeadint,handles.hpatternint,handles.hpatsubcoor], 'FontUnits','normalized','FontSize',0.3);
% ====================================================================

%% ============== TABLE OF INTERVALS ==================================
% table showing selected intervals, allows to delete individual intervals
handles.hlistinterval = uitab('Parent', handles.hintervals, 'Title', 'List of intervals', 'Units', 'normalized');
handles.heraseint     = uicontrol('Parent',handles.hlistinterval,'Style','pushbutton', 'String', 'Erase', 'Units',...
                'normalized', 'Position', [0.9,0.5,0.1,0.5], 'FontUnits','normalized', 'Enable', 'off',...
                'Callback',{@eraseint_callback});
% ====================================================================

%% ============== EXPERIMENTAL PARAMETERS =============================
% set, by input or measurement, radii (RBC, contact, pipette), pressute,
% pixel to micron ratio 
handles.hexpdata = uibuttongroup('Parent', handles.hfig, 'Title','Experimental parameters', 'Units','normalized',...
            'Position', [0.86,0.05,0.1,0.5],'Visible','off');
handles.hprestxt    = uicontrol('Parent', handles.hexpdata, 'Style', 'text', 'String', 'Pressure:',...
           'Units', 'normalized','Position', [0,0.6,0.5,0.12]);
handles.hpressure   = uicontrol('Parent', handles.hexpdata, 'Style', 'edit', 'String', num2str(handles.pressure),...
            'Units', 'normalized','Position', [0.5,0.6,0.45,0.2],'Callback', {@setexpdata_callback,handles.pressure}); 
handles.hRBCtxt     = uicontrol('Parent', handles.hexpdata, 'Style', 'pushbutton', 'String','<HTML><center>RBC<br>radius:</HTML>',...
            'Units', 'normalized','Position', [0,0.4,0.5,0.2],'Callback',@measureRBC_callback);
handles.hRBCrad     = uicontrol('Parent', handles.hexpdata, 'Style', 'edit', 'String', num2str(handles.RBCradius),...
            'Units', 'normalized','Position', [0.5,0.4,0.45,0.2],'Callback', {@setexpdata_callback,handles.RBCradius});
handles.hPIPtxt     = uicontrol('Parent', handles.hexpdata, 'Style', 'pushbutton', 'String', '<HTML><center>Pipette<br>radius:</HTML>',...
            'Units', 'normalized','Position', [0,0.2,0.5,0.2],'Callback',{@measureLength_callback,'pipette'});
handles.hPIPrad     = uicontrol('Parent', handles.hexpdata, 'Style', 'edit', 'String', num2str(handles.PIPradius),...
            'Units', 'normalized','Position', [0.5,0.2,0.45,0.2],'Callback', {@setexpdata_callback,handles.PIPradius}); 
handles.hCAtxt      = uicontrol('Parent', handles.hexpdata, 'Style', 'pushbutton', 'String', '<HTML><center>Contact<br>radius:</HTML>',...
            'Units', 'normalized','Position', [0,0,0.5,0.2],'Callback',{@measureLength_callback,'contact'});
handles.hCArad      = uicontrol('Parent', handles.hexpdata, 'Style', 'edit', 'String', num2str(handles.CAradius),...
            'Units', 'normalized','Position', [0.5,0,0.45,0.2],'Callback', {@setexpdata_callback,handles.CAradius});
handles.hP2Mtxt     = uicontrol('Parent', handles.hexpdata, 'Style', 'pushbutton', 'String', '<HTML><center>Pixel to<br>micron:</HTML>',...
            'Units', 'normalized','Position', [0,0.8,0.5,0.2],'Callback', {@measureLength_callback,'scale'});
handles.hP2M        = uicontrol('Parent', handles.hexpdata, 'Style', 'edit', 'String', num2str(handles.P2M),...
            'Units', 'normalized','Position', [0.5,0.8,0.45,0.2],'Callback', {@setexpdata_callback,handles.P2M});
set([handles.hRBCtxt,handles.hPIPtxt,handles.hCAtxt,handles.hP2Mtxt,handles.hprestxt],'HorizontalAlignment','center','FontUnits','normalized');
set([handles.hpressure,handles.hRBCrad,handles.hPIPrad,handles.hCArad,handles.hP2M],'FontUnits','normalized');
% ====================================================================

%% ================= VIDEO INFORMATION ================================
% only information about the video; read only fields
handles.hvidinfo = uipanel('Parent', handles.hfig,'Title','Video information', 'Units','normalized',...
            'Position', [0.05, 0.86, 0.25, 0.1]);
handles.hvidheight = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Height:', 'Position', [0,0.75,0.5,0.25]);
handles.hvidwidth = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Width:', 'Position', [0,0.5,0.5,0.25]);
handles.hvidduration = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Duration:', 'Position', [0,0.25,0.5,0.25]);
handles.hvidframes = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Frames:', 'Position', [0,0,0.5,0.25]);
handles.hvidframerate = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Framerate:', 'Position', [0.5,0,0.5,0.25]);
handles.hvidname = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Name:', 'Position', [0.5,0.25,0.5,0.25]);
handles.hvidformat = uicontrol('Parent', handles.hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Format:', 'Position', [0.5,0.5,0.5,0.25]);  
set([handles.hvidheight,handles.hvidwidth,handles.hvidduration,handles.hvidframes,handles.hvidframerate,...
    handles.hvidname,handles.hvidformat],'FontUnits','normalized');        
% ====================================================================

%% ================= RUNNING CALCULATION ==============================
% set calculation, buttons to create BFPClass object, run tracking, get
% force, plotting interface, select contrast,
handles.hcalc =     uipanel('Parent', handles.hfig, 'Title', 'Tracking', 'Units', 'normalized',...
                'Position', [0.76,0.05,0.1,0.5]);
handles.hupdate      =   uicontrol('Parent', handles.hcalc, 'Style','pushbutton','String', 'Update', 'Units', 'normalized',...
                'TooltipString','Commit modifications of tracking settings',...
                'Position', [0, 0.85, 0.5, 0.15], 'Enable', 'off', 'Callback', {@update_callback});
handles.hruntrack    =   uicontrol('Parent', handles.hcalc, 'Style', 'pushbutton', 'String', 'Track', 'Units', 'normalized',...
                'TooltipString','Start tracking procedure for commited intervals',...
                'Position', [0.5, 0.85,0.5,0.15], 'Enable', 'off','Callback', {@runtrack_callback});
handles.hrunforce    =   uicontrol('Parent', handles.hcalc, 'Style', 'pushbutton', 'String', '<HTML><center>Get<br>Force</HTML>', 'Units', 'normalized',...
                'TooltipString','Calculate stiffness and force time profile',...
                'Position', [0.5, 0.7,0.5,0.15], 'Enable', 'off','Callback', {@runforce_callback});            
handles.hgraphplot   =   uicontrol('Parent', handles.hcalc, 'Style', 'pushbutton', 'String', 'Plot', 'Units', 'normalized',...
                'Position', [0,0.5, 0.5, 0.15], 'Enable', 'off', 'Callback', {@graphplot_callback});
handles.hgraphitem   =   uicontrol('Parent', handles.hcalc, 'Style', 'popup', 'String', {'Contrast', 'Tracks (3D)', 'Trajectories (2D)', 'Force', 'Metrics'},...
                'Units','normalized','Position', [0,0.35,0.5,0.15], 'Enable', 'off',...
                'Callback', {@graphpopup_callback});
handles.hgraphbead   =   uicontrol('Parent', handles.hcalc, 'Style', 'checkbox', 'String', 'Bead', 'Enable', 'off',...
                'Units','normalized','Position', [0.5, 0.35, 0.5, 0.075]);
handles.hgraphpip    =   uicontrol('Parent',handles.hcalc, 'Style', 'checkbox', 'String', 'Pipette', 'Enable', 'off',...
                'Units','normalized','Position', [0.5, 0.425, 0.5, 0.075]);
handles.hlowplot     =   uicontrol('Parent', handles.hcalc,'Style','edit','String', num2str(handles.lowplot), 'Units','normalized',...
                'Position', [0.5,0.5,0.25,0.15], 'Enable','off','Callback', {@plotrange_callback,handles.lowplot,1});
handles.hhighplot    =   uicontrol('Parent', handles.hcalc,'Style','edit','String', num2str(handles.highplot), 'Units','normalized',...
                'Position', [0.75,0.5,0.25,0.15],'Enable','off', 'Callback', {@plotrange_callback,handles.highplot,2});
handles.hreport      =   uicontrol('Parent', handles.hcalc,'Style','pushbutton', 'String', '<HTML><center>View<br>Report</HTML>',...
                'Tooltipstring', 'Displays summary of the last tracking, illustrating intervals with poor trackability',...
                'Units','normalized','Position',[0,0.25,0.5,0.1],'Enable','off','Callback', {@getreport_callback});
handles.hlinearinfo  =   uicontrol('Parent', handles.hcalc,'Style','pushbutton','String','<HTML><center><font size="3" color="black">?</font></HTML>',...
                'Units','normalized','Position',[0,0.65,0.25,0.05],'Enable','off','Callback',{@lininfo_callback},...
                'TooltipString','Information on reliability of linear approximation of force');
handles.hstiffbtn    =   uicontrol('Parent', handles.hcalc,'Style','pushbutton','String','<HTML><center><font size="3" color="black">k</font></HTML>',...
                'Units','normalized','Position',[0.25,0.65,0.25,0.05],'Enable','off','Callback',{@stiffinfo_callback},...
                'TooltipString','Click here, if stiffness is not displayed correctly');            
% contrast type selection button group + radio buttons
handles.hcontype     =   uibuttongroup('Parent', handles.hcalc, 'Units', 'normalized',...
                'Position', [0.5,0.25,0.5,0.1],'SelectionChangedFcn', {@contype_callback});
handles.hSD2         =   uicontrol('Parent', handles.hcontype, 'Style', 'radiobutton', 'Units','normalized',...
                'String', 'SD2', 'Value', 1,'Position', [0,0.5,1,0.5]);
handles.hrSD2         =   uicontrol('Parent', handles.hcontype, 'Style', 'radiobutton', 'Units','normalized',...
                'String', 'rSD2', 'Value', 0, 'Position', [0,0,1,0.5]);
set([handles.hupdate,handles.hruntrack,handles.hrunforce,handles.hgraphplot,...
    handles.hgraphitem,handles.hgraphbead,handles.hgraphpip,handles.hlowplot,...
    handles.hhighplot,handles.hreport,handles.hlinearinfo,handles.hcontype,...
    handles.hSD2, handles.hrSD2],'FontUnits','normalized');
% ====================================================================

%% ========================= BASIC FITTING ============================
% set basic fitting, fit line, exponentiel, plateaux, set interval, set
% plateaux detection parameters (plat width etc)
handles.hfit        = uipanel('Parent',handles.hfig,'Title','Basic Fitting', 'Units','normalized',...
                'Position', [0.45,0.66,0.1,0.30]);
handles.hfitline    = uicontrol('Parent',handles.hfit,'Style','pushbutton','String','<HTML><center>Fit<br>line</HTML>',...
                'Units','normalized','Position',[0,0.85,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'line',false});
handles.hfitexp     = uicontrol('Parent',handles.hfit,'Style','pushbutton','String','<HTML><center>Fit<br>exponentiel</HTML>',...
                'Units','normalized','Position',[0,0.7,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'exp',false});
handles.hfitplateau = uicontrol('Parent',handles.hfit,'Style','pushbutton','String','<HTML><center>Fit<br>plateau</HTML>',...
                'Units','normalized','Position',[0,0.55,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'plat',false});
handles.hgetplatwidth = uicontrol('Parent',handles.hfit,'Style','edit','String', num2str(handles.kernelWidth),...
                'TooltipString', strcat('<HTML>Defines the sensitivity of differentiating kernel.<br>',...
                'The kernel is derivative of Gaussian. Sensitivity is then std of the original Gaussian.</HTML>'),...
                'Units','normalized','Position',[0,0.4,0.4,0.15],'Callback',{@getplat_callback,1},...
                'Visible','off');
handles.hplatwidth    = uicontrol('Parent',handles.hfit,'Style','pushbutton','String',strcat('<HTML><center>Sensitivity<br>',...
                num2str(round(handles.kernelWidth)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines the sensitivity of differentiating kernel.<br>',...
                'The kernel is derivative of Gaussian. Sensitivity is then &sigma of the original Gaussian.</HTML>'),...
                'Units','normalized','Position',[0,0.4,0.4,0.15],'Callback',{@platswitch_callback,handles.hgetplatwidth},...
                'Enable','off');
handles.hgetplatthresh= uicontrol('Parent',handles.hfit,'Style','edit','String', num2str(handles.noiseThresh),...
                'TooltipString', strcat('<HTML>Defines the threshold of noise.<br>',...
                'Multiple of std of force derivative to be still considered noise.</HTML>'),...
                'Units','normalized','Position',[0.4,0.4,0.3,0.15],'Callback',{@getplat_callback,2},...
                'Visible','off');                        
handles.hplatthresh   = uicontrol('Parent',handles.hfit,'Style','pushbutton','String',strcat('<HTML><center>Thresh<br>',...
                num2str(round(handles.noiseThresh,1)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines the threshold of noise.<br>',...
                'Multiple of std of force derivative to be still considered noise.</HTML>'),...
                'Units','normalized','Position',[0.4,0.4,0.3,0.15],'Callback',{@platswitch_callback,handles.hgetplatthresh},...
                'Enable','off');            
handles.hgetplatmin   = uicontrol('Parent',handles.hfit,'Style','edit','String', num2str(handles.minLength),...
                'TooltipString', strcat('<HTML>Defines minimal length of plateau.<br>',...
                'Minimal number of continuous frames with derivative below threshold, to constitute a plateau.</HTML>'),...
                'Units','normalized','Position',[0.7,0.4,0.3,0.15],'Callback',{@getplat_callback,3},...
                'Visible','off');                        
handles.hplatmin      = uicontrol('Parent',handles.hfit,'Style','pushbutton','String',strcat('<HTML><center>Length<br>',...
                num2str(round(handles.minLength)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines minimal length of plateau.<br>',...
                'Minimal number of continuous frames with derivative below threshold, to constitute a plateau.</HTML>'),...
                'Units','normalized','Position',[0.7,0.4,0.3,0.15],'Callback',{@platswitch_callback,handles.hgetplatmin},...
                'Enable','off');   
handles.hfitint       = uicontrol('Parent',handles.hfit,'Style','pushbutton','String','<HTML><center>Choose<br>interval</HTML>',...
                'Units','normalized','Position',[0,0,1,0.15],'Callback',{@fitint_callback});  
set([handles.hfitline,handles.hfitexp,handles.hfitplateau,handles.hgetplatwidth,handles.hplatwidth,...
     handles.hgetplatthresh, handles.hplatthresh,handles.hgetplatmin,handles.hplatmin,handles.hfitint],'FontUnits','normalized');
% ====================================================================            

%% ================= IMPORT,EXPORT,UI SETTINGS ============================
% set IO setting, from-to fields, import-export buttons
handles.hio      = uipanel('Parent',handles.hfig,'Title','Import, export, UI settings', 'Units','normalized',...
            'Position', [0.31,0.66,0.14,0.30]);
handles.hvar     = uicontrol('Parent', handles.hio, 'Style', 'popupmenu', 'Units', 'normalized', 'String',...
            {'force & tracks'; 'frame'; 'graph'; 'parameters'}, 'Enable', 'on', 'Position',...
            [0,0.9,1,0.1], 'Callback', {@port_callback});
handles.htar     = uicontrol('Parent', handles.hio, 'Style', 'popupmenu', 'Units', 'normalized', 'String',...
            {'workspace'; 'data file'; 'figure/media'}, 'Enable', 'on', 'Position',...
            [0,0.6,1,0.1], 'Callback', {@port_callback});
handles.hexport  = uicontrol('Parent', handles.hio, 'Style','pushbutton','Units','normalized','String',...
            strcat('Export',char(8595)),...
            'Position', [0,0.75,0.5,0.15],'Callback',{@export_callback}, 'Enable','on');
handles.himport  = uicontrol('Parent', handles.hio, 'Style','pushbutton','Units','normalized','String',...
            strcat('Import',char(8593)),...
            'Position', [0.5,0.75,0.5,0.15],'Callback',{@import_callback}, 'Enable','off');
handles.hverbose = uicontrol('Parent', handles.hio, 'Style','checkbox','Units','normalized','String','Verbose output',...
            'Min', 0, 'Max', 1, 'Value',1 ,'Position', [0,0.4,1,0.15],'Callback',{@verbose_callback},...
            'TooltipString','Verbose output means more warnings, suggestions, dialog windows etc.');
handles.hhideexp = uicontrol('Parent',handles.hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.25,1,0.1],'String','Show experimental data panel','Callback',{@hidepanel_callback,'experimental data',handles.hexpdata});
handles.hhidelist= uicontrol('Parent',handles.hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.15,1,0.1],'String','Show tracking list panel','Callback',{@hidepanel_callback,'tracking list',[handles.hpatterns,handles.hbeadmethods]});
handles.hhidedet = uicontrol('Parent',handles.hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.05,1,0.1],'String','Show advanced detection panel','Callback',{@hidepanel_callback,'advanced detection',[handles.hpipdetection,handles.hbeaddetection]});
%hBDtest = uicontrol('Parent', handles.hio, 'Style', 'pushbutton','Units','normalized','Position', [0,0.25,1,0.15],...
%            'String', 'Disclose', 'TooltipString', 'Pay no attention to that man behind the curtain',...
%            'Callback', {@BDtest_callback});
set([handles.hvar,handles.htar,handles.hexport,handles.himport,handles.hverbose,handles.hhideexp,handles.hhidelist,handles.hhidedet],'FontUnits','normalized');
        
%% ============ LOAD OLDER SESSION PASSED AS ARGUMENT =================
    % if the data exist, load the saved environment
    % it is only called here, after the GUI is constructed
    if loadData; 
        loadEnvironment(loadData);
    end
% ====================================================================


%% ================= CALLBACK FUNCTIONS ===============================
%% Move mouse wheel to advance/rewind the video frame
    % mouse wheel action to advance or roll back the video frames
    function mouseplay_callback(~,data)
        if isempty(vidObj); return; end;    % without video, do nothing 
        c = handles.hfig.CurrentPoint;      % get coordinate at wheel time
        newframe = data.VerticalScrollCount + vidObj.CurrentFrame;  % calculate new frame to display
        if newframe <= 0 || newframe > vidObj.Frames                % check if in bounds
            return;
        end
        if ( c(1) >= axesposition(1) && c(1) <= axesposition(1)+axesposition(3) ) ...
        && ( c(2) >= axesposition(2) && c(2) <= axesposition(2)+axesposition(4) )
            setframe(newframe);     % move video to the new frame
        end
    end

%% Hide GUI panel
    % allows to hide a panel of functions (particularly for experimental
    % data panel, tracking lists panel and tracking parameters panel
    function hidepanel_callback(source,~,name,hpanel)
        val=source.Value;
        if val==1
            set(hpanel,'Visible','on');
            source.String = strjoin({'Hide',name,'panel'});
        elseif val==0
            set(hpanel,'Visible','off');
            source.String = strjoin({'Show',name,'panel'});
        end
    end

    % testing backdoorObj function
%    function BDtest_callback(source,~)
%        source.String = backdoorObj.getTest();
%    end

%% Import function
    % controls various import possibilities
    function import_callback(~,~)
        var = handles.hvar.Value;       % which variable is to be imported; 1=force & track, 2=frame, 3=graph, 4=parameters
        src = handles.htar.Value;       % target of the import; 1=workspace, 2=datafile, 3=figure
        
        if isempty(BFPobj)          % BFPobj was not yet instantiated
            BFPobj = BFPClass();    % call default constructor
        end;
        
        dlgstr = [];
        
        % nested function; prepares import for various input types
        function importFeed(dataString)
            fileName = getFileName(strcat(dataString,'.dat'));
            inData = dlmread(fileName);
            BFPobj.importData(dataString,inData)
            set([handles.hgraphitem, handles.hgraphplot, handles.hlowplot, handles.hhighplot], 'Enable', 'on');
        end
                         
        switch var
            case 1  % force & tracks
                if src==1       % workspace - no action
                elseif src==2   % datafiles
                    if handles.verbose
                        dlgstr = strjoin({'Please be aware, that importing the force data or tracking data',...
                        'will overwrite the whole data structure calculated so far.',...
                        'There is no undo option. You would need to load Your settings again,',...
                        'using the button ''Update'' and perform the tracking and calculation.'});
                    end
                    
                    choice = questdlg(strcat({dlgstr;'Please select the type of data You want to import'}),...
                        'Import data type','Force','Pipette track', 'Bead track', 'Force');
                    
                    switch choice
                        case 'Force'
                            importFeed('force');
                        case 'Pipette track'
                            importFeed('pipPositions');
                            handles.hgraphpip.Enable = 'on';
                        case 'Bead track'     
                            importFeed('beadPositions');
                            handles.hgraphbead.Enable = 'on';
                    end
                            
                elseif tar==3;   % figure/image - no action
                end
                
            case 2  % frame
                % no import of individual frames; as for now, support of
                % import of frames from workspace of mediafiles might be
                % added
                
            case 3 % graph
                if src==1       % workspace
                    options=struct( 'Resize', 'off', 'WindowStyle','normal','Interpreter','tex' );
                    inHandle = inputdlg('Input name of the handle to the{\bf figure} You want to import:',...
                        'Import graph from workspace',1,{''},options);
                    if isempty(inHandle); return; end;
                    himportaxes = findobj(evalin('base',inHandle{1}),'Type','axes');    % gets handle of imported axes
                    cla(handles.hgraph);                                                        % clear the axes
                    himportgraph = copyobj(allchild(himportaxes), handles.hgraph);              % copy axes into handles.hgraph axes
                    set(himportgraph, 'HitTest','off');
                    handles.thisPlot = 6;       % flag saying fitting is possible, but data is outer
                elseif src==2   % datafile
                    % no datafile import - data can be easily imported and
                    % then plotted using GUI
                elseif src==3   % figure/image
                    inipath = fullfile(pwd,'graph.fig');
                    [name, dir] = uigetfile({'*.fig;','Figure files (*.fig)'},...
                                'Select a figure file for import',inipath); 
                    if isempty(name) || isempty(dir); return; end;              % if empty, return
                    figName = fullfile(dir,name);
                    importfig = openfig(figName,'new','invisible');
                    himportaxes = findobj(importfig,'Type','axes');
                    cla(handles.hgraph);
                    himportgraph = copyobj(allchild(himportaxes), handles.hgraph);      % copy axes into handles.hgraph axes
                    set(himportgraph, 'HitTest','off');
                    handles.thisPlot = 6;
                    delete(importfig);
                end
                
            case 4  % parameters
                if src==1       % workspace - no action
                elseif src==2   % datafile (here .mat file)
                    fileName = getFileName('BFPparameters.mat');
                    loadEnvironment(fileName);
                    assignin('base','BFPbackdoor',backdoorObj); % send the new backdoor to the base WS
                elseif src==3   % figure/image - no action
                end                  
            
        end
    end

%% Export function
    % controls various combinations of figure elements and targets of export
    function export_callback(~,~)
        var = handles.hvar.Value;       % which variable is to be exported; 1=force & track, 2=frame, 3=graph, 4=parameters
        tar = handles.htar.Value;       % target of the export; 1=workspace, 2=datafile, 3=figure
        
        switch var
            case 1  % force & tracks
                if tar==1       % workspace
                    assignin('base','force',BFPobj.force);
                    assignin('base','pipPositions',BFPobj.pipPositions);
                    assignin('base','beadPositions',BFPobj.beadPositions);
                elseif tar==2   % datafiles
                    fileName = putFileName('force.dat');
                    if isequal(fileName,0); return; end;    % return if cancelled
                    force = zeros(BFPobj.trackedFrames,2);  % prealocate
                    i=1;
                    for frm=BFPobj.minFrame:BFPobj.maxFrame
                        force(i,:) = [frm, BFPobj.getByFrame(frm,'force')];
                        i=i+1;
                    end
                    dlmwrite(fileName, force);
                    fileName = putFileName('pipPositions.dat');
                    if isequal(fileName,0); return; end;    % return if cancelled
                    pipPos = zeros(BFPobj.trackedFrames,3);
                    i=1;
                    for frm=BFPobj.minFrame:BFPobj.maxFrame
                        pipPos(i,:) = [frm, BFPobj.getByFrame(frm,'pipette')];
                        i=i+1;
                    end
                    dlmwrite(fileName, pipPos);
                    fileName = putFileName('beadPositions.dat');
                    if isequal(fileName,0); return; end;    % return if cancelled
                    beadPos = zeros(BFPobj.trackedFrames,3);
                    i=1;
                    for frm=BFPobj.minFrame:BFPobj.maxFrame
                        beadPos(i,:) = [frm, BFPobj.getByFrame(frm,'bead')];
                        i=i+1;
                    end
                    dlmwrite(fileName, beadPos);                    
                elseif tar==3;   % figure/image - no action
                end
                
            case 2  % frame
                if tar==1       % workspace
                    capture = getframe(handles.haxes);
                    assignin('base','capturedFrame', capture);
                elseif tar==2;  % datafile - no action
                elseif tar==3   % figure/media
                    htempfig = figure('Name','transient','Visible','on');
                    hnewaxes = copyobj(handles.haxes,htempfig);
                    set(hnewaxes, 'Units','normalized','OuterPosition',[0,0,1,1]);  % save access, fill the whole figure
                    colormap(hnewaxes,gray);            % makes sure colormap is gray
                    fileName = putFileName('frame.bmp');% call to set up filepath
                    if isequal(fileName,0); return; end;    % return if cancelled
                    saveas(htempfig,fileName);          % save the trans. figure
                    delete(htempfig);
                end
                
            case 3 % graph
                if tar==1       % workspace
                    hexportfig = figure('Name','BFP - graph');
                    hexportgraph = copyobj(handles.hgraph, hexportfig);
                    set(hexportgraph, 'Units', 'normalized', 'OuterPosition', [0,0,1,1]);
                    set(allchild(hexportgraph),'HitTest','on');
                    assignin('base','BFPgraph',hexportfig);
                elseif tar==2   % datafile
                    if isempty(handles.thisPlot); 
                        if handles.verbose; helpdlg('Nothing plotted. Try to replot.','Empty graph');end;
                        return;
                    else
                        % delete descriptive line (these are not exported)
                        if ~isempty(handles.hzeroline); handles.hzeroline.delete; end;
                        if ~isempty(handles.pushtxt); handles.pushtxt.delete; end;
                        if ~isempty(handles.pulltxt); handles.pulltxt.delete; end;
                        lines = findobj(handles.hgraph,'type','line');  % get lines in the graph
                        if isempty(lines);  % abort if no graphlines
                            warn('No data object to export found in the graph.'); 
                            return;
                        end;                            
                        graphData = []; % declare, empty
                        switch handles.thisPlot
                            case 1          % contrast; any non-contrast line is discarded! (e.g. fit lines)
                                graphData.name = putFileName('contrastGraph.dat');
                                if isequal(graphData.name,0); return; end;    % return if cancelled
                                if numel(lines) > 1;    % contrast should be a single line
                                    tcont = vidObj.getContrastByFrame(handles.thisRange(1),handles.contype);
                                    for child = 1:numel(lines)
                                        if lines(child).YData(1) ==  tcont;
                                            graphData.coor(:,1) = lines(child).XData;
                                            graphData.coor(:,2) = lines(child).YData;
                                            break;
                                        end
                                    end
                                else
                                    graphData.coor(:,1) = lines.XData;
                                    graphData.coor(:,2) = lines.YData;
                                end                                                               
                            case { 2, 3 }   % trajectories and metrics
                                for child = 1:numel(lines)  % 2 lines
                                    
                                    if ~isempty(lines(child).ZData)
                                        graphData(child).coor(:,1) = get(lines(child),'ZData');
                                    else
                                        graphData(child).coor(:,1) = handles.thisRange(1):handles.thisRange(2);
                                    end;
                                    graphData(child).coor(:,2) = get(lines(child),'XData');
                                    graphData(child).coor(:,3) = get(lines(child),'YData');
                                    
                                    if graphData(child).coor(1,2:3) == BFPobj.getByFrame(handles.thisRange(1),'bead');
                                        graphData(child).name = putFileName('beadGraph.dat');
                                        if isequal(graphData(child).name,0); return; end;    % return if cancelled
                                    elseif graphData(child).coor(1,2:3) == BFPobj.getByFrame(handles.thisRange(1),'pipette');
                                        graphData(child).name = putFileName('pipGraph.dat');
                                        if isequal(graphData(child).name,0); return; end;    % return if cancelled
                                    end
                                    
                                end
                            case 4  % force
                                graphData.name = putFileName('forceGraph.dat');
                                if isequal(graphData.name,0); return; end;    % return if cancelled
                                graphData.coor(:,1) = lines.XData;
                                graphData.coor(:,2) = lines.YData;
                            case 5  % metrics
                                tmetrics = BFPobj.getByFrame(handles.thisRange(1),'metric'); % read values for the first frame
                                for child = 1:numel(lines)  % 2 lines
                                    graphData(child).coor(:,1) = lines(child).XData;
                                    graphData(child).coor(:,2) = lines(child).YData;                                    
                                    if graphData(child).coor(1,2) == tmetrics(1);
                                        graphData(child).name = putFileName('beadmetricGraph.dat');
                                        if isequal(graphData(child).name,0); return; end;    % return if cancelled
                                    elseif graphData(child).coor(1,2) == tmetrics(2);
                                        graphData(child).name = putFileName('pipmetricGraph.dat');
                                        if isequal(graphData(child).name,0); return; end;    % return if cancelled
                                    else
                                        warn('Export failed, graph could not be matched with underlying data');
                                        graphData = []; % delete
                                        return;         % and abort
                                    end
                                end
                        end
                        for child = 1:numel(graphData)
                            dlmwrite(graphData(child).name, graphData(child).coor);
                        end
                    end
                elseif tar==3   % figure/image
                    htempfig = figure('Name','transient','Visible','on');
                    hnewaxes = copyobj(handles.hgraph,htempfig);
                    set(hnewaxes, 'Units','normalized','OuterPosition',[0,0,1,1]);  % save access, fill the whole figure
                    fileName = putFileName('BFPgraph.fig'); % call to set up filepath
                    if isequal(fileName,0); return; end;    % return if cancelled
                    saveas(htempfig,fileName);              % save the trans. figure
                    delete(htempfig);
                end
                
            case 4  % parameters
                if tar==1       % workspace - no action
                elseif tar==2   % datafile (here .mat file)
                    fileName = putFileName('BFPparameters.mat');
                    if isequal(fileName,0); return; end;    % return if cancelled
                    saveEnvironment(fileName);     % saves the whole workspace (all variables) to the file
                elseif tar==3   % figure/image - no action
                end                  
            
        end
    end

%% I/O settings for various in/out target combinations
    % choosing various combinations of target/source for import/export; not
    % all the combinations are possible
    function port_callback(~,~)
        var = handles.hvar.Value;
        tar = handles.htar.Value;
        
        switch var  % variable switch
            case 1  % force & tracks
                switch tar
                    case 1  % workspace
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'off'; %!!!
                    case 2  % datafile
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'on';
                    case 3  % figure; no IO for data <-> figure
                        handles.hexport.Enable = 'off';
                        handles.himport.Enable = 'off';
                        if handles.verbose; 
                            helpdlg(strjoin({'Export of data into figure and visa versa is not possible.',...
                                'If You wish to use data to produce figure, You can export them to the Matlab basic workspace.'}),...
                                'Unsupported export/import');
                        end;
                end
            case 2  % frame
                switch tar
                    case 1  % workspace
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'off';
                    case 2  % datafile
                        handles.hexport.Enable = 'off'; % no frame export to data
                        handles.himport.Enable = 'off';
                        if handles.verbose;
                            helpdlg(strjoin({'Export of frame into datafile (i.e. not image or figure) is not possible',...
                                'If You wish to export current frame into external file, use media or figure file.'}),...
                                'Unsupported export/import');
                        end
                    case 3  % figure/media
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'off';
                end
            case 3 % graph
                switch tar
                    case 1  % workspace
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'on';
                    case 2  % datafile
                        handles.hexport.Enable = 'on';  % exports underlying data into datafile
                        handles.himport.Enable = 'off'; % no import of data into graph, they can plot them elsewhere
                    case 3  % figure/media
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'on';  % figure only
                end
            case 4  % parameters
                switch tar
                    case 1  % workspace
                        handles.hexport.Enable = 'off';
                        handles.himport.Enable = 'off';
                        if handles.verbose;
                            helpdlg('Export and import of parameters between workspaces is currently not possible.',...
                                    'Unsupported import/export');
                        end
                    case 2  % datafile
                        handles.hexport.Enable = 'on';
                        handles.himport.Enable = 'on';
                    case 3
                        handles.hexport.Enable = 'off';
                        handles.himport.Enable = 'off';
                        if handles.verbose; 
                            helpdlg('Export of parameters into figure and visa versa is not possible.', 'Unsupported export/import');
                        end;
                end
        end        
    end

%% Set verbose or more silent input
    % sets the 'handles.verbose' flag; this usually switches warning
    % dialogs to command line warnings
    function verbose_callback(source,~)
        handles.verbose = logical(source.Value);
    end

%% Change UI control (mostly button) for input (edit field)
    % changes UI to allow user input; for plateaux detection
    function platswitch_callback(source,~,setter)
        source.Visible = 'off';
        setter.Visible = 'on';
    end

%% Read input value (edit field) and set variable
    % reads and sets the value from the UI element; plateaux detection
    function getplat_callback(source,~,var)
        val = str2double(source.String);
        if ( isnan(val) || val < 0 )
            warndlg('The input must be a positive number.','Incorrect input','replace');
            switch var
                case 1
                    source.String = num2str(handles.kernelWidth);
                case 2
                    source.String = num2str(handles.noiseThresh);
                case 3
                    source.String = num2str(handles.minLength);
            end
            return;
        end
        source.Visible = 'off';
        switch var
            case 1
                handles.kernelWidth = val;
                handles.hplatwidth.String = strcat('<HTML><center>Sensitivity<br>',...
                num2str(round(handles.kernelWidth)),'</HTML>');
                handles.hplatwidth.Visible = 'on';
            case 2
                handles.noiseThresh = val;
                handles.hplatthresh.String = strcat('<HTML><center>Thresh<br>',...
                num2str(round(handles.noiseThresh,1)),'</HTML>');
                handles.hplatthresh.Visible = 'on';
            case 3
                handles.minLength = val;
                handles.hplatmin.String = strcat('<HTML><center>Length<br>',...
                num2str(round(handles.minLength)),'</HTML>');
                handles.hplatmin.Visible = 'on';
        end
    end
    
%% Fitting function
    % fitting the graph; only one type of fitting line at the time; fitted
    % line is redrawn; every separate line object is fittend by a line
    % (i.e. several fitting lines for discontiguous graph)
    function fit_callback(~,~,type,limit)
        
        % delete descriptive objects
        if ~isempty(handles.hzeroline); handles.hzeroline.delete; end;
        if ~isempty(handles.pushtxt); handles.pushtxt.delete; end;
        if ~isempty(handles.pulltxt); handles.pulltxt.delete; end;
        
        getcursor_callback(0,0,true);   % delete possible point marker
        
        % fitted lines are persistent; erased every time fitting is called
        persistent hfitplot;
        persistent hsublimplot;
        if numel(hfitplot); 
            for p=1:numel(hfitplot);    % erase graphical elements from ...
                hfitplot(p).ph.delete;  % ... the plotter area
                hfitplot(p).txt.delete;
            end;
            hfitplot = [];              % clear now empty structure
        end
        if numel(hsublimplot); 
            for p=1:numel(hsublimplot); 
                hsublimplot(p).ph.delete;
                hsublimplot(p).txt.delete;
            end;
            hsublimplot = [];
        end
        
        if handles.thisPlot ~= 4 && handles.thisPlot ~= 1 && handles.thisPlot ~=5 && handles.thisPlot ~= 6
            choice = questdlg(['The fitting procedure is available only for force, contrast, metrics and imported outer graph',...
                    'Would You like to switch graph?'],'Data fitting','Force','Contrast','Metrics', 'Force');
            switch choice
                case 'Force'
                    handles.toPlot = 4;
                    handles.hgraphitem.Value = handles.toPlot;
                    graphplot_callback(0,0);
                case 'Contrast'
                    handles.toPlot = 1;
                    handles.hgraphitem.Value = handles.toPlot;
                    graphplot_callback(0,0);
                case 'Metrics'
                    handles.toPlot = 5;
                    handles.hgraphitem.Value = handles.toPlot;
                    graphplot_callback(0,0);
                otherwise
                    return;
            end
        end
        
        % set up descriptive strings
        switch handles.thisPlot
            case 4    % force
                units  = '\; pN$$';
                unit   = ' pN/s';
                lunits = '\frac{pN}{s}$$';
                quant = '$$\bar{F}=';
                rnd = 1;
            case 1  % contrast
                units  = '$$';
                unit   = ' per second';
                lunits = '\; s^{-1}$$';
                quant = '$$\bar{C}=';
                rnd = 3;
            case 5  % metrics
                units = '$$';
                unit  = ' per second';
                lunits = '\; s^{-1}$$';
                quant = '$$\bar{\mu}=';
                rnd = 3;
        end
        
        eunits = '\; s^{-1}$$'; % the same for all cases
        
        % set fitting interval
        if isempty(handles.fitInt); 
            handles.fitInt = [ handles.hgraph.XLim(1), 0; handles.hgraph.XLim(2), 0] ;   % if none provided, select current graph limits
            handles.hfitint.String = strcat('<HTML><center>Change<br>[',num2str(round(handles.fitInt(1,1))),',',...
                         num2str(round(handles.fitInt(2,1))),']</HTML>');                % save the info about the current fitting interval
        end
        
        iniInt = [handles.fitInt(1,1), handles.fitInt(2,1)];   % set the selected interval
        xdata = struct('data',[]);          % initialize variable for data range
        ydata = struct('data',[]);          % initialize variable for the data to be fit
        
        hplotline = findobj(handles.hgraph,'Type','line');  % find the data line
        for l = 1:numel(hplotline)
            xdata(l).data = (max(hplotline(l).XData(1),iniInt(1)):min(hplotline(l).XData(end),iniInt(2)))';
            if isempty(xdata(l).data) || strcmp(hplotline(l).Tag,'intbound');
                xdata(l).data = [];
                ydata(l).data = [];
            else ydata(l).data = hplotline(l).YData(xdata(l).data - hplotline(l).XData(1)+1)';
            end
        end;
        
        % prune empty items
        for l=numel(xdata):-1:1
            if isempty(xdata(l).data);
                xdata(l) = [];
                ydata(l) = [];
            end
        end
            
        nextPlateau = 1;
        
        hold(handles.hgraph,'on');
        
        for l=1:numel(ydata) % for all fitted data lines
            switch type
                case 'line'
                    [ coeff, err ] = polyfit( xdata(l).data, ydata(l).data, 1);
                    [ ffrc, ~ ] = polyval( coeff, xdata(l).data, err );
                    disp(strcat('Fitted slope: ',num2str(coeff(1)*vidObj.Framerate), unit) );
                    hfitplot(l).ph = plot(handles.hgraph, xdata(l).data, ffrc, 'r', 'HitTest', 'off');
                    str = strcat('$$r=',num2str(round(coeff(1)*vidObj.Framerate,2,'significant')),lunits);
                    pos = 0.5*[ (xdata(l).data(end) + xdata(l).data(1)), (ffrc(end)+ffrc(1)) ];
                    hfitplot(l).txt = text( 'Parent', handles.hgraph, 'interpreter', 'latex', 'String', str, ...
                'Units', 'data', 'Position', pos, 'Margin', 1, 'FontUnits','normalized',...
                'LineStyle','none', 'HitTest','off','FontSize',handles.fitfontsize, 'FontWeight','bold','Color','red',...
                'VerticalAlignment','top');
                case 'exp'
                    if ~isempty(vidObj)     % make sure vidObj exist, if it doesn't, outer data are being fit
                        if (vidObj.Framerate ~= 0)
                            [ coeff, ffrc ] = expfit( xdata(l).data, ydata(l).data, 'framerate', vidObj.Framerate );
                        end
                    else    % case for imported data
                        [ coeff, ffrc ] = expfit( xdata(l).data, ydata(l).data );
                    end
                    disp(strcat('Time constant: ',num2str(coeff(1)),{' '},'s') );
                    str = strcat('$$\eta=',num2str(round(1/coeff(1),3,'significant')),eunits);
                    pos = 0.5*[ (xdata(l).data(end) + xdata(l).data(1)), (ffrc(end)+ffrc(1)) ];
                    hfitplot(l).txt = text( 'Parent', handles.hgraph, 'interpreter', 'latex', 'String', str, ...
                'Units', 'data', 'Position', pos, 'Margin', 1, 'FontUnits','normalized',...
                'LineStyle','none', 'HitTest','off','FontSize',handles.fitfontsize, 'FontWeight','bold','Color','red',...
                'VerticalAlignment','middle');
                    hfitplot(l).ph = plot(handles.hgraph, xdata(l).data, ffrc, 'r', 'HitTest', 'off');
                case 'plat'
                    sf = backdoorObj.edgeDetectionKernelSemiframes;         % default 10
                    if numel(xdata(l).data) < (2*sf + 5)      % require at least 4 points with analysis
                        warndlg('Interval is too short for analysis','Insufficient data', 'replace');
                        return;
                    end
                    locint = xdata(l).data(sf:end-sf);      % crop the ends; dfrc at those frames would be padded
                    sw = 2 * handles.kernelWidth^2;         % denominator of Gaussian
                    dom = -sf:sf;                           % domain (in number of frames)
                    gauss = exp(-dom.^2/sw);                % the gaussian
                    dgauss = diff(gauss);                   % differentiating gaussian kernel to get edge detector
                    dfrc = abs(conv(ydata(l).data,dgauss,'valid'));   % differentiating the force; keeping only unpadded values
                    thresh = handles.noiseThresh*std(dfrc);         % threshold for noise
                    ffrc = (dfrc < thresh);                 % any slope below noise is plateaux
                    limits = [0,0];
                    
                    if ~exist('plateaux','var') || isempty(plateaux)
                        plateaux(1).limits = limits;
                    else
                        plateaux(end+1).limits = limits;
                    end;
                    
                    for i=1:numel(ffrc)
                        if (ffrc(i) && limits(1) == 0)      % plateau and not counting yet; first frame
                            if i > sf; limits(1) = i; end;  % plateau can't start in a padded zone
                        elseif ( (ffrc(i) && i < numel(ffrc)) && limits(1) ~= 0)    % plateau and counting; add a frame
                            limits(2) = i;
                        elseif ( (~ffrc(i) || i==numel(ffrc)) && limits(1) ~= 0)    % not plateau and counting; the last frame
                            if (limits(2) - limits(1)) > handles.minLength;         % if plateau long enough
                                plateaux(end).limits = limits;                      % add to list
                                plateaux(end+1).limits = [0,0];                     % new default range
                            end
                            limits = [0,0];
                        end
                    end     
                    
                    % erase the last prepared
                    if numel(plateaux); plateaux(end) = []; end;         
                    
                    % testing if plateaux are under the contrast limit,
                    % used for initial contrast analysis
                    if limit
                        sub = (ydata(l).data < backdoorObj.contrastPlateauDetectionLimit);
                        dsub = diff(sub);
                        dsub_s = (find(dsub == 1)+1);
                        dsub_e = (find(dsub == -1));
                        if sub(1); dsub_s = [1;dsub_s]; end;
                        if sub(end); dsub_e = [dsub_e; numel(sub)]; end;
                        subints = [dsub_s, dsub_e];
                        for k=size(subints,1):-1:1
                            if(subints(k,2)-subints(k,1) < backdoorObj.contrastPlateauDetectionLimitLength)
                                subints(k,:) = [];  % erase too short sublimit intervals
                            else
                                hsublimplot(end+1).ph = ...
                                plot(handles.hgraph, subints(k,1):subints(k,2),...
                                backdoorObj.contrastPlateauDetectionLimit*ones(1,subints(k,2)-subints(k,1)+1),...
                                'b', 'HitTest', 'off','LineWidth',2);
                                pos = [ 0.5*(subints(k,1)+subints(k,2)), backdoorObj.contrastPlateauDetectionLimit ];
                                if (mod(k,2)==0); va='bottom'; else va='top';end;
                                hsublimplot(end).txt = text( 'Parent', handles.hgraph, 'String', strcat('[',num2str(subints(k,1)),':',num2str(subints(k,2)),']'), ...
                                'Units', 'data', 'Position', pos, 'Margin', 1,'interpreter', 'latex', 'FontUnits','normalized', ...
                                'LineStyle','none', 'HitTest','off','FontSize',handles.fitfontsize, 'Color','blue',...
                                'VerticalAlignment',va, 'HorizontalAlignment','center');
                                disp(strcat('Low contrast warning: [',num2str(subints(k,1)),',',num2str(subints(k,2)),']'));
                            end
                        end
                    end
                    
                    % generally fitting plateaux
                    fitted = ydata(l).data(sf:end-sf);  % crop the fits to match data with frames
                    for p=nextPlateau:numel(plateaux)
                        lim = plateaux(p).limits;
                        plateaux(p).avgfrc = mean( fitted(lim(1):lim(2)) );
                        if handles.thisPlot==1 && limit    % if there's limit on contrast
                            if plateaux(p).avgfrc > backdoorObj.contrastPlateauDetectionLimit;
                                continue;   % proceed to the next plateau
                            end;
                        end;
                        pOnScreen = numel(hfitplot)+1;  % make sure there are no gaps in line list
                        hfitplot(pOnScreen).ph = plot(handles.hgraph, locint(lim(1):lim(2)), plateaux(p).avgfrc*ones(1,lim(2)-lim(1)+1), 'r', 'HitTest', 'off','LineWidth',2);
                        disp(strcat('Average plateau value [',num2str(locint(lim(1))),',',num2str(locint(lim(2))),']:',num2str(plateaux(p).avgfrc)) );
                        str = strcat(quant,num2str(round(plateaux(p).avgfrc,rnd)),units);
                        pos = [ 0.5*(locint(lim(1))+locint(lim(2))), plateaux(p).avgfrc ];
                        if (mod(pOnScreen,2)==0); va='bottom'; else va='top';end;
                        hfitplot(pOnScreen).txt = text( 'Parent', handles.hgraph, 'interpreter', 'latex', 'String', str, ...
                        'Units', 'data', 'Position', pos, 'Margin', 1, 'FontUnits','normalized',...
                        'LineStyle','none', 'HitTest','off','FontSize',handles.fitfontsize, 'FontWeight','bold','Color','black',...
                        'VerticalAlignment', va, 'HorizontalAlignment','center');
                    end     
                    nextPlateau = numel(plateaux)+1;
            end
        end
    end

%% Fitting interval selection
    % this is a bit tricky with preserving correct settings for hit test,
    % video frame-graph click connection, no freeze etc
    % select interval for fitting; make sure to try/catch
    function fitint_callback(~,~)
        if handles.selecting;       % there is a strange interplay between uiwait/waitfor functions ...
            warn('select');         % ...this approach is a bit awkward, but fail-safe
            return;
        else handles.selecting = true; 
        end;
        set([handles.hfitline,handles.hfitexp,handles.hfitplateau],'Enable','off'); % suspend fitting
        handles.hgraph.ButtonDownFcn = [];      % suppress button-down callback for the graph
        handles.hfitint.String = '<HTML><center>Accept<br>Interval</HTML>';
        handles.hfitint.Tag = 'wait';
        handles.hfitint.Callback = @(src,~)(set(src,'Tag','continue'));
        hold(handles.hgraph,'on');
        BCfunction = makeConstrainToRectFcn('impoint',get(handles.hgraph,'XLim'),get(handles.hgraph,'YLim'));
        Ymid = (handles.hgraph.YLim(2)+handles.hgraph.YLim(1))*0.5;
        if isempty(handles.fitInt)
            Xlen = handles.hgraph.XLim(2)-handles.hgraph.XLim(1);
            XC = [handles.hgraph.XLim(1)+0.25*Xlen, handles.hgraph.XLim(1)+0.75*Xlen];
            oldInt = round( [handles.hgraph.XLim(1), 0;...
                             handles.hgraph.XLim(2), 0] );
        else
            oldInt = handles.fitInt;
            XC = [max(handles.fitInt(1,1),handles.hgraph.XLim(1)),min(handles.fitInt(2,1),handles.hgraph.XLim(2))];
        end 
        intpoint(1) = impoint(handles.hgraph,XC(1),Ymid,'PositionConstraintFcn',BCfunction);
        intpoint(2) = impoint(handles.hgraph,XC(2),Ymid,'PositionConstraintFcn',BCfunction);
        intpoint(1).addNewPositionCallback(@(pos) fitintNewPosition_callback(pos,1));
        intpoint(2).addNewPositionCallback(@(pos) fitintNewPosition_callback(pos,2));
        waitfor(handles.hfitint,'Tag','continue');
        try
            handles.fitInt = round([ intpoint(1).getPosition(); intpoint(2).getPosition() ]);
        catch
            warn('interrupt',...
                'Original interval was restored (or set to default in case of an empty original interval)');
            handles.fitInt = oldInt;
        end
        intpoint(1).delete;                 % remove points
        intpoint(2).delete;
        fitintNewPosition_callback(0,0);    % remove red lines and assoc. coordinates
        set([handles.hfitline,handles.hfitexp,handles.hfitplateau,handles.hplatwidth,handles.hplatthresh,handles.hplatmin],'Enable','on');  % activate fitting buttons
        handles.hfitint.String = strcat('<HTML><center>Change<br>[',num2str(round(handles.fitInt(1,1))),',',...
                                num2str(round(handles.fitInt(2,1))),']</HTML>');
        handles.hfitint.Callback = @fitint_callback;        
        handles.hgraph.ButtonDownFcn = {@getcursor_callback};       % return the the general button callback
        set([handles.hfitline,handles.hfitexp,handles.hfitplateau],'Enable','on'); % restore fitting
        handles.selecting = false;

    end

%% Support function for fitting interval setting
    % callback called when impoint gets new position
    function fitintNewPosition_callback(coor,var)
        nvar = mod(var,2)+1;
        persistent hline;
        if isempty(hline);
            hline = struct('ph',[],'cx',[]);
            hline(2) = hline(1);
        end;
        if(var==0)  % remove both; delete the ph graphs
            if ~isempty(hline(1).ph); hline(1).ph.delete; end;  % delete graphs
            if ~isempty(hline(2).ph); hline(2).ph.delete; end;
            if ~isempty(hline(1).cx); hline(1).cx = []; end;    % remove coordinates
            if ~isempty(hline(2).cx); hline(2).cx = []; end;
            return;
        end
        if ~isempty(hline(var).ph); hline(var).ph.delete; end;  % delete old line
        yl = handles.hgraph.YLim;
        hline(var).ph = plot(handles.hgraph, [coor(1), coor(1)], handles.hgraph.YLim, 'r', 'HitTest','off');
        hline(var).ph.Tag = 'intbound';
        ylim(handles.hgraph,yl);
        hline(var).cx = coor(1);
        if isempty(hline(nvar).cx); hline(nvar).cx = handles.fitInt(nvar,1); end;
        handles.hfitint.String = strcat('<HTML><center><font color="red">Accept<br>[',num2str(round(hline(1).cx)),',',...
                                num2str(round(hline(2).cx)),']</HTML>');
    end

%% Returns position of the cursor click, draws vertical line in the graph
    % return coordinates of cursor on the graph; delcall is only deleting
    % the marking in the graph
    function getcursor_callback(source,~,delcall)
        if ~exist('delcall','var'); delcall = false; end;   % for full calls set to false
        if isempty(handles.thisPlot); return; end;  % if there is no plot yet, ignore the call
        persistent hline;
        persistent hdot;
        if ~isempty(hline); hline.delete; end;  % delete old selection, if any
        if ~isempty(hdot); hdot.delete; end;    % delete old selection, if any
        if delcall; return; end;    % if only delete call, stop here
        hold(handles.hgraph,'on');        
        coor = get(source, 'CurrentPoint');
        if (coor(1,1) < handles.hgraph.XLim(1) || coor(1,1) > handles.hgraph.XLim(2)); return; end; % ignore clicks outside the canvas
        if (handles.thisPlot == 1 || handles.thisPlot==4 || handles.thisPlot==5)
            if handles.thisPlot == 1;       % contrast
                Ycoor = vidObj.getContrastByFrame(round(coor(1,1)),handles.contype);
            elseif handles.thisPlot == 4;   % force
                Ycoor = BFPobj.getByFrame(round(coor(1,1)),'force');
            elseif handles.thisPlot == 5;   % metrics
                Ycoor = BFPobj.getByFrame(round(coor(1,1)),'metric');   % returns [bead, pipette]
            end
            yl = ylim(handles.hgraph); 
            hline = plot(handles.hgraph, [coor(1,1), coor(1,1)], handles.hgraph.YLim, 'r','HitTest','off');
            hdot = plot(handles.hgraph, coor(1,1), Ycoor(1),'or','MarkerSize',10, 'LineWidth',2, 'HitTest','off');
            ylim(handles.hgraph,yl);    % block Y-axis rescaling
            if numel(Ycoor)==2; 
                hdot(2) = plot(handles.hgraph, coor(1,1), Ycoor(2),'or','MarkerSize',10, 'LineWidth',2, 'HitTest','off');
                disp( ['Metrics (bead,pipette): [' num2str(round(coor(1,1))),',', num2str(Ycoor(1)),',', num2str(Ycoor(2)),']'] );
            else
                disp( ['Coordinate: [' num2str(round(coor(1,1))),',', num2str(Ycoor),']'] );
            end;
            setframe(round(coor(1,1)));     % case of contrast, force, metrics
        elseif handles.thisPlot == 3
            disp( ['Coordinate: [' num2str(coor(1,1)),',', num2str(coor(1,2)),']'] );
            hdot = plot(handles.hgraph, coor(1,1),coor(1,2),'or','MarkerSize',10, 'LineWidth',2);
        end
        handles.hgraph.ButtonDownFcn = {@getcursor_callback}; 
    end

%% Call to generate tracking fidelity report
    % displays report of the last tracking, illustrating poorly trackable
    % intervals, showing metrics as an overlay
    function getreport_callback(~,~)
        BFPobj.generateReport();
    end

%% Select item to plot
    % selection of plotted quantity from drop-down menu
    function graphpopup_callback(source,~)
        handles.toPlot = source.Value;
    end
       
%% Set frame range of plot
    % set the range for plot
    function plotrange_callback(source,~,oldval,var)
       handles.lowplot = round(str2double(handles.hlowplot.String));            % save the values
       handles.highplot = round(str2double(handles.hhighplot.String));
       handles.hlowplot.Callback  = {@plotrange_callback,handles.lowplot,1};    % reset old values in callback
       handles.hhighplot.Callback = {@plotrange_callback,handles.highplot,2};
       % revert for incorrect input
       if (isnan(handles.lowplot)||isnan(handles.highplot)||handles.lowplot > handles.highplot||handles.lowplot < 1||handles.highplot > vidObj.Frames) 
           warndlg({'Input values must be numeric, positive, low value smaller than high value';
                    'Please correct the input and retry'},'Incorrect input', 'replace');
           source.String = num2str(oldval);
           if (var==1); handles.lowplot = oldval;
           else handles.highplot = oldval; end;
           return;
       end;
    end

%% Plotting control function
    % plot selected quantity (numbered 1-5), #1 contrast measure (SD2,
    % rSD2), #2 tracks (3D) with 3rd axis as time, #3 trajectories (2D), #4
    % force (+ right y-axis as deformation), #5 metrics
    function graphplot_callback(~,~)
        camup(handles.hgraph,'auto');
        campos(handles.hgraph,'auto');
        rotate3d off;
        grid(handles.hgraph,'off');
        switch handles.toPlot
            case 1  % contrast
                reset(handles.hgraph);
                handles.fitInt = [handles.lowplot,0;handles.highplot,0];
                getcontrast_callback(0,0,'user');  % calls contrast procedure to calculate and plot contrast
            case 2  % tracks
                if (handles.hgraphpip.Value || handles.hgraphbead.Value)
                    BFPobj.plotTracks(handles.hgraph,handles.lowplot,handles.highplot,logical(handles.hgraphpip.Value),logical(handles.hgraphbead.Value),'Style','3D');  % call plotting function with lower and upper bound
                    handles.thisRange = [handles.lowplot, handles.highplot];
                    grid(handles.hgraph,'on');
                    camup(handles.hgraph,[-1, -1, 1]);   
                    campos(handles.hgraph,[handles.hgraph.XLim(2),handles.hgraph.YLim(2),handles.hgraph.ZLim(2)]);
                    hrot = rotate3d(handles.hgraph);
                    hrot.Enable = 'on';
                    setAllowAxesRotate(hrot,handles.haxes,false);
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
            case 3  % trajectories
                if (handles.hgraphpip.Value || handles.hgraphbead.Value)
                    BFPobj.plotTracks(handles.hgraph,handles.lowplot,handles.highplot,logical(handles.hgraphpip.Value),logical(handles.hgraphbead.Value),'Style','2D');  % call plotting function with lower and upper bound
                    handles.thisRange = [handles.lowplot, handles.highplot];
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
            case 4  % force
                BFPobj.plotTracks(handles.hgraph,handles.lowplot,handles.highplot,false,false,'Style','F','Calibration',handles.calibrated);
                handles.thisRange = [handles.lowplot, handles.highplot];
                if numel(BFPobj.force)~=0;
                    plotZeroLine();     % plots dashed red line at y=0 to indicate pulling and pushing
                end;
            case 5  % metrics
                if (handles.hgraphpip.Value || handles.hgraphbead.Value)
                    BFPobj.plotTracks(handles.hgraph,handles.lowplot,handles.highplot,logical(handles.hgraphpip.Value),logical(handles.hgraphbead.Value),'Style','M');
                    handles.thisRange = [handles.lowplot,handles.highplot];
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
        end
        handles.thisPlot = handles.toPlot;
        handles.hgraph.ButtonDownFcn = {@getcursor_callback};
    end    

%% Generate LaTeX annotation with stiffness intformation in a new window
    % displays information about stiffness in a new window
    function stiffinfo_callback(~,~)
        boxoptions.Interpreter = 'latex';
        boxoptions.WindowStyle = 'modal';
        hmb=msgbox(strjoin({'$$k=',num2str(round(BFPobj.k)),'\frac{pN}{\mu m}$$',char(10),...
            '$$\Delta k=\pm',num2str(round(BFPobj.Dk)),'\frac{pN}{\mu m}$$'}),...
            'Stiffness info', boxoptions);
    end

%% Display info about linear equation for RBC stiffness validity
    % displays information about reliability of the linear approximation of
    % force-extension relation
    function lininfo_callback(~,~)
        if handles.overLimit
            warndlg(strjoin({'The detected extensions of the RBC suggest, that the force-extension',...
                'relation might be out of the linear regime. Reliability depends on many parameters,'...
                'as a rule of a thumb,',num2str(BFPobj.linearLimit),'microns thershold was chosen.'...
                'Linear approximation tends to over-estimate the force, but even for extensions nearing'...
                'one micron, error would be around 20%. In such cases, infotext reporting stiffness is'...
                'displayed in red.'}),'RBC extension over linear limit','replace');
        else
            warndlg(strjoin({'The detected extensions of the RBC are within the boundaries of'...
                'linear approximation. In such cases, infotext reporting stiffness is displayed'...
                'in blue.'}),'RBC extension within linear limit','replace');
        end
    end

%% Call to start force calculation
    % gets parameters for calculation, calculates (& shows) 'k', gets force
    % checks if initial probe parameters were modified and issues warning
    function runforce_callback(~,~)
        % if verbose and geometric parameters were not changed, warn
        if (handles.RBCradius == RBC && handles.PIPradius == PIP && handles.CAradius == CON)    % nothing measured
            if handles.verbose  % report
                choice = questdlg(strjoin({'This action runs force calculation. The force, however,',...
                    'must be calibrated (i.e. stiffness ''k'' calculated) using experiment settings dependent parameters',...
                    'adjustable in ''Experimental parameters'' panel. Initially, it contains only order of magnitude',...
                    'values, to give an idea of force time dependence. If You want to have results properly',...
                    'calibrated for Your experiment, please review these values before the calculation.'}),...
                    'Parameters for force calculation', 'Review', 'Proceed', 'Review');
                if strcmp(choice,'Review'); return; end;
            end;
            handles.calibrated = false; % mark not calibrated and continue
        else
            handles.calibrated = true;   % likely calibration occured; set force to calibrated
        end
        BFPobj.getParameters(handles.RBCradius, handles.CAradius, handles.PIPradius, handles.pressure);
        handles.stiffness = BFPobj.k;
        handles.overLimit = BFPobj.getForce(handles.hgraph, handles.calibrated);
        handles.hlinearinfo.Enable = 'on';
        handles.hstiffbtn.Enable = 'on';
        handles.toPlot = 4;
        handles.thisPlot = 4;
        handles.hgraphitem.Value = handles.thisPlot;
        handles.lowplot = max(handles.hgraph.XLim(1),1);
        handles.highplot = min(handles.hgraph.XLim(2),BFPobj.maxFrame);
        handles.thisRange = [handles.lowplot,handles.highplot];
        handles.hlowplot.String = num2str(handles.lowplot);
        handles.hhighplot.String = num2str(handles.highplot);
        tmplines = findobj(handles.hgraph,'type','line');
        if ~isempty(tmplines)
            plotZeroLine(); % mark line of zero force
        end
        makeStiffAnot();    % display RBC stiffness info
        handles.hgraph.ButtonDownFcn = {@getcursor_callback};
    end

%% Call to start bead and pipette tracking accross pre-selected intervals
    % runs tracking procedure
    function runtrack_callback(~,~)
        BFPobj.Track(handles.hgraph);       % run tracking
        handles.hgraph.ButtonDownFcn = {@getcursor_callback};   % reset callback
        set([handles.hrunforce,handles.hgraphplot,handles.hlowplot,handles.hhighplot,...
            handles.hgraphbead,handles.hgraphpip, handles.hgraphitem,handles.hreport],'Enable','on');
        handles.toPlot = 2;
        handles.thisPlot = 2;
        handles.lowplot = max(BFPobj.minFrame,1);
        handles.highplot = BFPobj.maxFrame;
        handles.thisRange = [handles.lowplot,handles.highplot];
        handles.hlowplot.String = num2str(handles.lowplot);
        handles.hhighplot.String = num2str(handles.highplot);
        handles.hgraphitem.Value = handles.thisPlot;
    end

%% Update BFPClass object containing tracking and force settings
    % procedure to create BFPClass object, which performs all the
    % calculations; if object exist, it is overwritten with settings
    % currently selected in the GUI
    function update_callback(~,~)
        BFPobj = BFPClass(vidObj.Name, vidObj ,handles.intervallist);
        BFPobj.getBeadParameters(handles.beadradius,handles.beadbuffer,handles.beadsensitivity,handles.beadgradient,handles.beadmetricthresh,handles.P2M);
        BFPobj.getPipParameters(handles.pipmetricthresh, handles.contrasthresh, handles.pipbuffer);
        set([handles.hruntrack,handles.hgenfilm],'Enable','on');        
    end

%% Add an interval to the set of tracking intervals
    % adds currently defined interval to the list of intervals
    % runs mady integrity checks, communicates issues to the user, performs
    % corrections and even runs small functions to get user input;
    % Note that this is quite complex and cornerstone function. It manages
    % the interval addition in a way the final interval list retains
    % integrity and the tracking results are then clear and meaningful.
    function addinterval_callback(~,~)
        
        % make input interval copy, to track corrective changes
        origint = [];
        origint = strucopy(origint,handles.interval);
        extracalibration = false;
        
        % check if initial frame of the interval is frame of origin of the
        % pipette pattern. This test is important to clarify, if the
        % pipette patter selected matches the pattern of the interval
        if ( handles.interval.frames(1) ~= handles.tmppatframe && handles.interval.frames(1) ~= handles.updpatframe)
            initrackdlg = warndlg({'Selected pipette pattern does not originate at the first frame of the proposed interval';...
                     'Program will attempt to search the pattern in the frame, to verify its contrast compatibility and autoset the initial coordinates for search in this interval.'},...
                     'Remote pipette pattern','replace');
            waitfor(initrackdlg);   % wait for user to read the message
            
            [ position, ~ ] = TrackPipette( vidObj, handles.interval.pattern, [-1 -1], [handles.interval.frames(1) handles.interval.frames(1)] );
            
            % draw recognized pattern on the interval first frame
            hold(handles.haxes,'on');
            setframe(handles.interval.frames(1));
            patrect = rectangle('Parent', handles.haxes, 'Position', ...
                [position(2), position(1), size(handles.interval.pattern,2), size(handles.interval.pattern,1)],...
                'EdgeColor','r','LineWidth', 2 );
            hold(handles.haxes,'off');
            
            % ask user to accept or discard
            choice = questdlg({strjoin({'Program attempted to localize the selected pattern in the first frame of the interval.',...
                      'The pattern is highlighted in red. If the position is correct, please accept the suggestion.',...
                      'If pattern is gravely misplaced, the program was unable to localize it.',...
                      'This is almost certainly caused by contrast incopatibility between the pattern You selected and its appearance in this interval.',...
                      'Either try to select a compatible patter or remove the interval from tracking'})},...
                      'Pipette initial coordinate autodetection', 'Accept', 'Cancel', 'Accept');
            
            % explanation: The selected pipette pattern originates in
            % a frame outside the interval being added. The algorithm tries
            % to localize the pattern in the initial frame of the interval.
            % To assure the resulting force is compatible, we need to use
            % the same anchor and the same reference frame. If the pipette
            % pattern is already in another interval, the program will keep
            % its 'referece' and 'anchor'. If it is added from the pattern
            % list, program will copy the 'anchor' and the frame of origin
            % as a default 'reference'.
            
            switch choice
                case 'Accept'
                    handles.interval.patcoor = [position(2), position(1)];      % save the recorded position in the frame
                    handles.hpatternint.String = strcat('[',num2str(round(handles.interval.patcoor(1))),',',num2str(round(handles.interval.patcoor(2))),...
                                    ';',num2str(handles.interval.frames(1)),']');
                    handles.tmppatframe;    % original frame of the pattern is kept, hidden;
                    handles.updpatframe = handles.interval.frames(1);   % but information about update is kept;
                case 'Cancel'
                    handles.interval.patcoor = [];
                    handles.interval.pattern = [];
                    handles.hpatternint.String = '[.,.;.]';
                    patrect.delete; % remove rectangle
                    return;         % cancel adding interval
            end
            
            patrect.delete;
            
        end
        
        % verify if bead initial coordinate originates in the initial frame
        % - unlike pattern, for bead, this is obligatory
        if ( handles.interval.frames(1) ~= handles.tmpbeadframe )
            warndlg({strjoin({'Initial frame of the interval does not match the frame of origin of initial bead coordinates.',...
                'The initial bead coordinate must be specified for the interval initial frame.'});...
                'Please make the necessary corrections and try again.'},...
                'Bead frame mismatch', 'replace');
            return;
        end;
        
        % verify all the necessary fields exist and are filled
        for f=1:numel(intfields);
            if (~isfield(handles.interval,intfields{f}) || isempty(handles.interval.(intfields{f})))
                warndlg(strcat('The field',{' '}, intfields{f}, ' is missing or empty. Provide all the required information.'),...
                        'Field missing','replace');
                return;
            end
        end
        
        % verify the values of the interval and refframes
        if ~(isinvideo(handles.interval.frames(1)) && isinvideo(handles.interval.frames(2)) && isinvideo(handles.interval.reference))
            warndlg(strjoin({strcat('One or more of the specified frames, first frame (', num2str(handles.interval.frames(1)),'), ',...
                                                                       'or last frame (', num2str(handles.interval.frames(2)),'), of the interval,'),...
                    strcat('or the reference frame (', num2str(handles.interval.reference), ')'),...
                    strcat('have incorrect value, or value out of bounds of the video: [1,',num2str(vidObj.Frames),'].'),...
                    'Please review the values and try to add the interval again.'}));
            return;
        end
        
        % verify intervals do not overlap
        if numel(handles.intervallist) > 0;
            review = false;     % flag for abort and review, if intervals partially overlap
            modified = false;
            for i=1:numel(handles.intervallist)
                if (handles.interval.frames(1) < handles.intervallist(i).frames(2) &&...
                    handles.interval.frames(2) > handles.intervallist(i).frames(1))
                
                    old = [handles.interval.frames(1), handles.interval.frames(2)]; % save original timespan
                    if handles.interval.frames(1) >= handles.intervallist(i).frames(1);
                        handles.interval.frames(1) = max(handles.interval.frames(1),handles.intervallist(i).frames(2));
                        modified = ~modified;   % toggle
                    end
                    if handles.interval.frames(2) <= handles.intervallist(i).frames(2)
                        handles.interval.frames(2) = min(handles.interval.frames(2),handles.intervallist(i).frames(1));
                        modified = ~modified;
                    end
                    
                    handles.hstartint.String = num2str(handles.interval.frames(1));
                    handles.hendint.String = num2str(handles.interval.frames(2));
                    if modified;    % only one limit was changed, i.e. intervals are not mutual subsets
                        warndlg({strcat('Added interval [',num2str(old(1)),',',num2str(old(2)),...
                                '] overlaps with another existing interval, [', num2str(handles.intervallist(i).frames(1)),',',...
                                num2str(handles.intervallist(i).frames(2)),'].');...
                                strcat('Please note intervals should be exclusive. New interval was modified to [',...
                                num2str(handles.interval.frames(1)),',',num2str(handles.interval.frames(2)),']. Please review and submit again.')},...
                                'Overlapping intervals','replace');
                        review = true;
                    else
                        warndlg({strcat('Added interval [',num2str(old(1)),',',num2str(old(2)),...
                                '] is subset or superset of another existing interval, [', num2str(handles.intervallist(i).frames(1)),',',...
                                num2str(handles.intervallist(i).frames(2)),']. Please review.')},...
                                'Duplcite intervals', 'replace');
                        handles.interval.frames = old;  % reset original values
                        handles.hstartint.String = old(1);
                        handles.hendint.String = old(2);
                        return; % if interval is subset of another interval, abort immediatelly
                    end    
                end
            end
            if review; return; end; % after overlaps are sorted out, let user review
        end
    
        % verify reference frame is part of the interval being added; in
        % case reference is external, issue contrast change risk warning;
        % the pipette must be local for this interval
        if ( handles.interval.reference >= handles.interval.frames(1) && handles.interval.reference <= handles.interval.frames(2) ) && ...
           ( handles.tmppatframe >= handles.interval.frames(1) && handles.tmppatframe <= handles.interval.frames(2) );
            passed = true;  % eligible reference frame; reference and pattern originate in the interval
        elseif ( handles.interval.reference >= handles.interval.frames(1) && handles.interval.reference <= handles.interval.frames(2) )
            hw = warndlg({'The reference frame originates in this interval, but the pipette pattern originates in another interval.';...
                     'It is allowed, but make sure the tracked pipette pattern has a compatible contrast and can be recognized in this interval.'},...
                     'External frame of pipette pattern','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        elseif ( handles.tmppatframe >= handles.interval.frames(1) && handles.tmppatframe <= handles.interval.frame(2) )
            hw = warndlg({'The pipette pattern originates in this interval, but the reference frame does not belong to the added interval.';...
                     'It is allowed, but make sure the frame of reference has a compatible contrast and uses the same pipette pattern as in this interval.'},...
                     'External frame of reference','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        else
            hw = warndlg({'The reference frame does not belong to the added interval and neither does pipette pattern originate in the interval.';...
                     'It is allowed, but make sure the frame of reference has a compatible contrast and uses the same pipette pattern as in this interval.';...
                     'The same goes for the pipette pattern, make sure it has a compatible contrast and can be recognized in this interval.'},...
                     'External reference frame','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        end;
        
        % compare the reference and anchor used with the data at the 
        % intervals already added. If one pattern with two different
        % settings was forced into the list, the result will be a horrible
        % mess I do not want to fix. This is not GTA to give people insane
        % stunt bonus.
        if ~passed
             [ rframe, ranchor,~ ] = ...  % validate; as validation is with confirmation, suppress warning message (the last passed variable)
                 validatepattern(handles.interval.pattern,handles.interval.reference,handles.interval.patsubcoor,true);
 
            if (rframe == handles.interval.reference) && all(ranchor == handles.interval.patsubcoor);  % let pass                
            else
                if (rframe ~= handles.interval.reference)
                    strref = strjoin({'The reference frame (i.e. zero-strain frame) You chose,',...
                    num2str(handles.interval.reference),',is different from the reference frame',...
                    'previously chosen for the identical pipette pattern,', num2str(rframe),'.'});
                else
                    strref = '';
                end
                if any(ranchor ~= handles.interval.patsubcoor)
                    stranch = strjoin({'The anchor point You chose,'...
                    strcat('[',num2str(round(handles.interval.patsubcoor(1))),',',num2str(round(handles.interval.patsubcoor(2))),']'),...
                    ',is different from the anchor point previously chosen for the identical pipette pattern,',...
                    strcat('[',num2str(round(ranchor(1))),',',num2str(round(ranchor(2))),'].')});
                else
                    stranch = '';
                end
             
                choice = questdlg(strjoin({strref,char(10), stranch,char(10),...
                    'This may be an unnecesasry warning, but please make sure,',...
                    'that the pattern, reference frame and anchor are compatible across the intervals,',...
                    'in order to get compatible force readings across the intervals.'}),...
                    'Incompatibility between intervals','Keep current','Review','Use previous','Keep current');
                switch choice
                    case 'Keep current';    % let pass
                    case 'Use previous';    % reset to previously used values
                        handles.interval.reference  = rframe;
                        handles.interval.patsubcoor = ranchor;
                    case 'Review'           % make corrections
                        return;
                end
            end
        end
        
        % finally, if reference frame be not part of any analysed interval,
        % add the calibration frame as a single-frame interval, before
        % proceeding with the major addition of user defined interval
        [ ~,~, absent ] = (validatepattern(handles.interval.pattern,handles.interval.reference,handles.interval.patsubcoor,true));
        if absent && ... % if the pattern is absent in other intervals and also in the currently added
           (handles.interval.reference < handles.interval.frames(1) || handles.interval.reference > handles.interval.frames(2));
       
            oldframe = vidObj.CurrentFrame; % save the currently set frame
       
            handles.calibint = [];
            handles.calibint = strucopy(handles.calibint,handles.interval); % pattern, patsubcoor, reference are preserved
            handles.calibint.frames = [handles.interval.reference,handles.interval.reference];
            handles.calibint.beadcoor = [];
            handles.calibint.contrast = [];

            hcalibfig = buildCalibFig();    % call function to construct single-frame calibration figure
            
            waitfor(hcalibfig);
            
            setframe(oldframe); % reset the original frame
            
            if ~isempty(handles.calibint)
                if ~isempty(handles.calibint.beadcoor) && ~isempty(handles.calibint.contrast)
                    handles.intervallist = strucopy(handles.intervallist,handles.calibint);
                    extracalibration = true;
%                     warn('Calibration single-frame interval was successfully added.');
                else
                    warndlg(strjoin({'Selected reference (zero strain) frame,', num2str(handles.interval.reference),...
                    ', does not belong to any present interval, neither to interval being added.',...
                    'The attempt to add calibration frame failed, probably due improper bead selection.',...
                    'The adding will now abort.'}),...
                    'Unaccessible reference point', 'replace');
                    return;
                end
            else
                warndlg(strjoin({'Selected reference (zero strain) frame,', num2str(handles.interval.reference),...
                    ', does not belong to any present interval, neither to interval being added. ',...
                    'The attempt to add calibration frame failed, probably due pipette uncompliance.',...
                    'The adding will now abort.'}),...
                    'Unaccessible reference point', 'replace');
                return;
            end
            
        end
        
        % if all checks are passed, add interval to the list and report to
        % the table of intervals;
        handles.intervallist = strucopy(handles.intervallist,handles.interval);

        makeTab();  % call external function to generate the table from the intervallist
           
        % generate addition report
        % fields { 'pattern', 'patcoor', 'beadcoor', 'patsubcoor', 'contrast','reference','frames' }
        strep = 'Following semi-automatic changes were made:\n\n';
        none = true;
        for f=1:numel(intfields);
            repline = [];
            if ~isequal(handles.interval.(intfields{f}),origint.(intfields{f}))
                none = false;
                switch intfields{f}
                    case 'pattern'
                        repline = '\n Different pattern was used.';
                    case {'patcoor', 'beadcoor', 'patsubcoor', 'frames'}
                        switch intfields{f}
                            case 'patcoor'
                                name = 'Pattern coordinate';
                            case 'beadcoor'
                                name = 'Bead coordinate';
                            case 'patsubcoor'
                                name = 'Anchor point';
                            case 'frames'
                                name = 'Frame interval';
                        end
                        repline = strjoin({'\n', name, 'was changed from the old value [',...
                            num2str(round(origint.(intfields{f})(1))),',',num2str(round(origint.(intfields{f})(2))),']',...
                            'to the new value of [',...
                            num2str(round(handles.interval.(intfields{f})(1))),',',num2str(round(handles.interval.(intfields{f})(2))),']'});
                    case 'contrast'
                        repline = strjoin({'\n','Contrast was switched from',origint.(intfields{f}),...
                                  'to',handles.interval.(intfields{f})});
                    case 'reference'
                        repline = strjoin({'\n','The frame of reference was changed from',...
                                num2str(round(origint.(intfields{f}))),'to',num2str(round(handles.interval.(intfields{f})))});
                end
            end        
            if ~isempty(repline); strep = sprintf(strcat(strep,repline)); end;
        end
        if extracalibration;
            strep = sprintf(strjoin({strep,'\n','Single-frame calibration interval was added.'}));
            none = false;
        end
        if none; strep='Interval was added without any further modifications.'; end;
        
        msgbox(strep,'Interval addition report','modal');        
        
        % clear interval to be reused; clear UI data; clear temp. variables
        % reset tracking interval to fault-free combination
        handles.interval = struct('frames',[round(vidObj.CurrentFrame),round(vidObj.Frames)]);  % rounding might not be necessary
        set(handles.hstartint, 'String', num2str(handles.interval.frames(1)),...
            'Callback',{@setintrange_callback,handles.interval.frames(1),1});   % reset range and callback parameters
        set(handles.hendint, 'String', num2str(handles.interval.frames(2)),...
            'Callback',{@setintrange_callback,handles.interval.frames(2),2});
        handles.hrefframe.String = [];
        handles.hpatternint.String = '[.,.;.]';
        handles.hbeadint.String = '[.,.;.]';
        handles.hpatsubcoor.String = '[.,.]';
        handles.updpatframe = 0;
        handles.tmppatframe = [];
        
        % disable the buttons
        handles.hgetpattern.Enable = 'off';
        handles.hselectpat.Enable = 'off';
        handles.hshowpattern.Enable = 'off';
        handles.hgetpatsubcoor.Enable = 'off';
        handles.haddinterval.Enable = 'off';
        handles.hgetrefframe.Enable = 'off';
        
        % enable Update button
        handles.hupdate.Enable = 'on';
    
    end

%% Marks an interval in the interval list for removal
    % selects table lines (intervals from intervallist) to be removed
    function rmtabledint_callback(hT, data)
        row = data.Indices(1);
        col = data.Indices(2);
        if data.EditData            % selected for removal
            handles.remove(end+1) = row;    % get selected row for removal
            hT.Data{row,col} = true;
        else
            [is,ind] = find(handles.remove==row);
            if is; handles.remove(ind) = []; end;   % remove the index
            hT.Data{row,col} = false;
        end
        
        if numel(handles.remove) > 0; handles.heraseint.Enable = 'on';
        else handles.heraseint.Enable = 'off'; end
        
    end

%% Call to erase selected intervals from the list
    % removes all selected entries from the interval list and the table
    function eraseint_callback(~,~)
        if numel(handles.remove) > 0;
            handles.remove = sort(handles.remove,'descend');    % the elements are deleted from the end            
            
            for ind=1:numel(handles.remove)             % remove intervals from the list
                handles.intervallist(handles.remove(ind)) = [];
            end
            
            handles.remove = [];                        % erase remove list
            handles.heraseint.Enable = 'off';           % switch off the button
            
            makeTab();      % remake table of intervals
        end
    end

    % allows to select the pattern anchor
    function getpatsubcoor_callback(~,~)        
        if ~isfield(handles.interval,'pattern') || isempty(handles.interval.pattern);
            warndlg('Choose a pipette pattern first. Then select the anchor.','No pipette pattern selected','replace');
            return;
        end;
        choice = questdlg(strjoin({'The anchor point defines a precise coordinate point on the pipette to',...
            'calculate red blood cell extension. The anchor is determined when pattern is initially',...
            'selected. If the same pattern (with the same time frame of reference distance) is used',...
            'in several intervals, it is necessary to keep the same anchor, in order to have comparable',...
            'calculated force across the intervals. Changing the anchor for one of the intervals is possible,',...
            'but keep in mind the results from different intervals may not be mutually compatible.'}),...
            'Anchor change', 'Proceed', 'Cancel', 'Cancel');
        if strcmp(choice, 'Cancel')
            return;
        end
        inPattern = handles.interval.pattern;   % input pattern
        hpatfig  = figure;  % create new figure with a button, displaying the pattern
        hpataxes = axes('Parent',hpatfig, 'Units','normalized','Position',[0,0.2,1,0.8]);
        imagesc(handles.interval.pattern, 'Parent',hpataxes);
        colormap(gray);
        axis(hpataxes,'image');
        haccept = uicontrol('Parent',hpatfig, 'Style', 'pushbutton', 'String', 'Accept',...
                'Units','normalized','Enable','off','Position',[0.2,0,0.2,0.15],'Callback','uiresume(gcbf)');
        BCfunction = makeConstrainToRectFcn('impoint',get(hpataxes,'XLim'),get(hpataxes,'YLim'));
        beadpoint = impoint(hpataxes,'PositionConstraintFcn', BCfunction);
        try
            haccept.Enable = 'on';              % enable 'accept' btn
            uiwait(gcf);                        % wait for acceptance (only one button)
            subcoor = (beadpoint.getPosition);  % read the value
            if isequal(inPattern,handles.interval.pattern)  % check if the pattern was not changed in the meantime
                handles.interval.patsubcoor = subcoor;      % save new selected value
                handles.hpatsubcoor.String = strcat('[',num2str(round(subcoor(1))),','...
                                ,num2str(round(subcoor(2))),']');   % update the string
            else
                warn('The pattern was changed during anchor selection process.',...
                        'No changes were made.');
            end
        catch
            warn('interrupt','Original value of anchor was kept, any possible input discarded.');
        end
        beadpoint.delete;   % delete the impoint object
        if isgraphics(hpatfig); close(hpatfig); end;     % close the figure (if not closed)
    end

%% Set the video frame to the first frame of current interval
    % set current frame to the first frame of the interval; useful when
    % selecting initial bead position
    function gotointframe_callback(~,~)
        if isempty(handles.interval) || ~isfield(handles.interval,'frames') ||...
           isempty(handles.interval.frames) || handles.interval.frames(1) == 0;
            setframe(vidObj.CurrentFrame);
            handles.hstartint.String = num2str(vidObj.CurrentFrame);
            handles.interval.frames(1) = vidObj.CurrentFrame;            
        else
            setframe(handles.interval.frames(1));
        end
    end

%% Get the selected bead in the list as the bead for current interval
    % saves the currently open bead coor for this interval to track
    function getintbead_callback(~,~)
        % check if there is a bead in the list to add
        if numel(handles.beadlist)==0 || isempty(handles.beadlist(handles.hbeadinilist.Value));
            warn('No bead has been added to the list');
            return;
        end;
        
        val = handles.hbeadinilist.Value;
        if handles.interval.frames(1) ~= handles.beadlist(val).frame
            choice = questdlg(strjoin({'The frame of origin of the selected bead',...
                'does not match the initial frame of the interval. You can update the initial frame,',...
                'cancel and choose another bead from the list, or select the bead directly on the screen.'}),...
                'Frame mismatch','Update','Cancel','Select','Update');
            switch choice
                case 'Update'
                    handles.hstartint.String = num2str(handles.beadlist(val).frame);
                    handles.interval.frames(1) = handles.beadlist(val).frame;
                case 'Cancel'
                    return;
                case 'Select'
                    getpoint_callback(handles.hselectbead,0,'interval');
                    return;
            end
        end
        handles.bead = handles.beadlist(val);
        handles.interval.contrast = handles.beadlist(val).contrast;
        handles.interval.beadcoor = handles.beadlist(val).coor;
        handles.tmpbeadframe = handles.beadlist(val).frame;
        handles.hbeadint.String = strcat('[',num2str(round(handles.interval.beadcoor(1))),',',num2str(round(handles.interval.beadcoor(2))),...
                                    ';',num2str(handles.tmpbeadframe),';',handles.interval.contrast,']');
        handles.hgetpattern.Enable = 'on';
        handles.hselectpat.Enable = 'on';
    end

%% Get selected pipette pattern from the list for the current interval
    % saves the currently open pattern for this interval to track
    function getintpat_callback(~,~)
        % check if there's a pattern in the list to add
        if numel(handles.patternlist)==0 || isempty(handles.patternlist(handles.hpatternlist.Value))
            warn('No pipette pattern in the list');
            return;
        end
        
        val = handles.hpatternlist.Value;
        handles.pattern = handles.patternlist(val);         % set last added pattern 
        handles.tmppatframe = handles.patternlist(val).frame;
        handles.updpatframe = 0;    % if pattern was matched to interval in the meantime, reset
        handles.interval.pattern = handles.patternlist(val).cdata;
        handles.interval.patcoor = handles.patternlist(val).coor;      
        [handles.interval.reference, handles.interval.patsubcoor,~] = ...
            validatepattern(handles.patternlist(val).cdata, handles.tmppatframe, handles.patternlist(val).anchor);
        handles.hrefframe.String = num2str(handles.interval.reference);
        handles.hpatsubcoor.String = strcat('[',num2str(round(handles.interval.patsubcoor(1))),','...
                            ,num2str(round(handles.interval.patsubcoor(2))),']');
        handles.hpatternint.String = strcat('[',num2str(round(handles.interval.patcoor(1))),',',num2str(round(handles.interval.patcoor(2))),...
                                    ';',num2str(handles.tmppatframe),']');
        handles.hgetpatsubcoor.Enable = 'on';
        handles.hshowpattern.Enable = 'on';
        handles.haddinterval.Enable = 'on';
        handles.hgetrefframe.Enable = 'on';
    end

%% Display selected pipette pattern
    % displays the pattern selected for the given interval
    function [hpatfig,hpataxes] = showintpattern_callback(~,~)
        if ~isfield(handles.interval,'pattern') || isempty(handles.interval.pattern);
            warn('Nothing to show. Select a pipette pattern first');
            return;
        end;
        hpatfig  = figure;  % open new figure
        hpataxes = axes('Parent',hpatfig);
        imagesc(handles.interval.pattern, 'Parent',hpataxes);   % display image (imagesc scales also intensity range)
        colormap(gray);                                 % grayscale image
        axis(hpataxes,'image');        
        if isfield(handles.interval,'patsubcoor')
            viscircles(hpataxes,handles.interval.patsubcoor,1,'EdgeColor','b');
        end;
    end

%% Attempts to correctly obtain the reference distance frame
    % get reference frame for the currently selected pattern
    function getrefframe_callback(~,~)
        if (~isfield(handles.interval,'pattern') || ...
            isempty(handles.interval.pattern));
            warn('Please select the pipette pattern tip first.','Reference frame is pattern-specific');
            return; 
        end;
        [handles.interval.reference, handles.interval.patsubcoor,~] = ...     % validate the pattern
            validatepattern(handles.interval.pattern, handles.interval.reference, handles.interval.patsubcoor);
        handles.hrefframe.String = num2str(handles.interval.reference);
        handles.hpatsubcoor.String = strcat('[',num2str(round(handles.interval.patsubcoor(1))),','...
                                ,num2str(round(handles.interval.patsubcoor(2))),']');
    end

%% Read input reference dist frame from edit field
    % set reference frame, where the RBC is not strained
    function setrefframe_callback(source,~,oldval)
        val = round(str2double(source.String));
        if (isnan(val) || val < 1 || val > vidObj.Frames)
            warndlg({'Input must be a positive number within the video limits.';'Input is rounded.'},...
                     'Incorrect input','replace');
            source.String = num2str(oldval);
            handles.interval.reference = [];        % set to non-input
            return;
        end                 
        handles.interval.reference = val;
        set(handles.hrefframe,'String', num2str(val), 'Callback', {@setrefframe_callback,val});
        
    end

%% Frame range of the interval selection
    % set the range of frames to track
    function setintrange_callback(source,~,oldval,num)
        in = str2double(source.String);
        % check if input is a valid number
        if (isnan(in) || in < 1 || in > vidObj.Frames)
            warndlg({'Input must be a positive number within the video limits.';'Input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = num2str(oldval);
            handles.interval.frames(num) = oldval;
            return;
        end
        low  = round(str2double(handles.hstartint.String));
        high = round(str2double(handles.hendint.String));
        % check if interval is at least one frame
        if (low > high)
            warndlg('The input range is empty. Original value will be reset.',...
                'Incorrect input','replace');
            source.String = num2str(oldval);
            handles.interval.frames(num) = oldval;
            return;
        end
        handles.interval.frames = [low,high];
        handles.hgetbead.Enable = 'on';        
        % all tests passed, update callback arguments for UIs
        handles.hstartint.Callback = {@setintrange_callback,low,1};
        handles.hendint.Callback = {@setintrange_callback,high,2};
    end

%% Measuring geometric properties of the probe
    % measure radius of the pipette, contact, scale by drawing a line
    function measureLength_callback(source,~,type)
        if handles.selecting; 
            warn('select');
            return;
        else handles.selecting = true; 
        end;
        
        microns = 5;
        
        if strcmp(type,'scale');
            micronstr = inputdlg(strjoin({'This function allows You to calibrate pixel-to-micron ratio',...
                'directly on the video image. You can draw a line across an object of known dimensions',...
                '(e.g. scalebar, bead, etc.). Please note that this information is directly available',...
                'from Your microscopy setup as a precise number; measuring it this way will yield poorer',...
                'precision. If You wishto proceed, input the length of the line in microns:'}),...
                'Video scale calibration',1,{num2str(microns)});
            if isempty(micronstr); 
                handles.selecting = false;
                return;
            end
            microns = str2double(micronstr);
            if isnan(microns) || microns <= 0
                warn('The input must be a positive number of type double.');
                handles.selecting = false;
                return;
            end                
        elseif handles.verbose;
            msgOptions.Interpreter = 'Latex';
            msgOptions.WindowStyle  = 'modal';
            msgbox(strjoin({'Select the {\bfseries diameter} of the', type,...
                '. The measured length will be converted into radius.'}),...
                'Radius measurement', msgOptions);
        end
        BCfunction = makeConstrainToRectFcn('imline',get(handles.haxes,'XLim'),get(handles.haxes,'YLim'));
        line = imline(handles.haxes,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        try
            LineEnds = line.getPosition;
            line.delete;
            length_ = norm( LineEnds(1,:)-LineEnds(2,:) );
            if strcmp(type,'pipette')
                handles.PIPradius = 0.5*length_*handles.P2M;
                handles.hPIPrad.String = num2str(round(handles.PIPradius,2));
            elseif strcmp(type,'contact')
                handles.CAradius = 0.5*length_*handles.P2M;
                handles.hCArad.String = num2str(round(handles.CAradius,2));
            elseif strcmp(type,'scale')
                handles.P2M = microns/length_;
                handles.hP2M.String = num2str(round(handles.P2M,2));
            end
        catch
            warn('interrupt',...
                strjoin({'The',type,'length detection failed, no changes were made.'}));
        end
        source.Callback = {@measureLength_callback,type};   % reset callback
        if strcmp(type,'scale'); 
            str='<HTML><center>Pixel to<br>micron:</HTML>'; 
        else
            Type = type;
            Type(1) = upper(type(1));
            str = strcat('<HTML><center>',Type,'<br>radius:</HTML>');   % reset string
        end;
        source.String = str;
        handles.selecting = false;
    end

%% Measuring the RBC radius
    % detects the RBC and measures its radius, using the TrackBead method;
    % TODO: make sure pixel to micron ratio is considered. If the RBC is
    % too large (or small) in the video, it wouldn't be detected
    function measureRBC_callback(source,~)
        if handles.selecting;   % make sure only one selection runs at a time
            warn('select');
            return;
        else handles.selecting = true;  % set handles.selecting flag
        end;
        BCfunction = makeConstrainToRectFcn('impoint',get(handles.haxes,'XLim'),get(handles.haxes,'YLim'));
        RBCpoint = impoint(handles.haxes,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        try     % this type of selection is very error-prone, if user doesn't follow the instructions
            RBCinicoor = (RBCpoint.getPosition);
            RBCframe = round(vidObj.CurrentFrame);
            RBCcontrast = questdlg('Does the red blood cell appear bright or dark?',...
                                   'RBC contrast','bright','dark','bright');
            [RBCcoor,RBCradius_,RBCmet,~] = TrackBead(vidObj,RBCcontrast,RBCinicoor,[RBCframe,RBCframe],...
                                       'radius',[20,30], 'sensitivity',0.95,'edge',0.1);
            if ( RBCradius_==0 ) % nothing detected
                warn(strjoin({'The RBC detection failed, no valid result returned.',...
                        'Make sure the cell is well visible, with clear edge (if possible)',...
                        'in the frame of selection, and try again.'}));
            else
                if RBCmet < handles.beadmetricthresh && handles.verbose
                    warn(strjoin({'The RBC was detected, but the strength of the detection',...
                        'is rather low, with',num2str(round(RBCmet,2)),'below the threshold of',...
                        num2str(handles.beadmetricthresh),'Review, if the detection appears correct.'}));
                end;
                hRBCshow = viscircles(handles.haxes,[RBCcoor(2),RBCcoor(1)],RBCradius_);
                found = questdlg('Was the RBC detected correctly?','Confirm RBC detection','Accept','Cancel','Accept');
                if strcmp(found, 'Accept')
                    handles.RBCradius = RBCradius_*handles.P2M;
                    handles.hRBCrad.String = num2str(round(handles.RBCradius,2));
                end
            end
        catch
            warn('interrupt');
        end
        RBCpoint.delete;
        source.Callback = {@measureRBC_callback};   % restore callback
        source.String = '<HTML><center>RBC<br>radius:</HTML>';
        pause(2);   % wait, so the user can see the RBC outline
        if exist('hRBCshow','var'); hRBCshow.delete; end;       % delete the RBC outline (if created)
        handles.selecting = false;  % remove handles.selecting flag
    end

%% Read and set input experimental values
    % set experimental parameters; validate input
    function setexpdata_callback(source,~,oldval)
        input = str2double(source.String);
        if isnan(input) || input < 0 
            source.String = num2str(oldval);
            warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
            return;
        end
        handles.pressure = str2double(handles.hpressure.String);
        handles.RBCradius = str2double(handles.hRBCrad.String);
        handles.PIPradius = str2double(handles.hPIPrad.String);
        handles.CAradius = str2double(handles.hCArad.String);
        handles.P2M = str2double(handles.hP2M.String);
        source.Callback = {@setexpdata_callback,input};
    end

%% Pipette buffer
    % set pipette tracking grace period
    function pipbuffer_callback(source,~)
        val = str2double(source.String);
        if isnan(val) || val < 0
            warndlg({'The grace period must be a positive number.';'Non-integer input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = num2str(handles.pipbuffer);
            return;
        end
        handles.pipbuffer = round(val);
        source.String = num2str(handles.pipbuffer);
    end

%% Setting thresholds for tracking
    % set contrast threshold value
    function pipcontrast_callback(source,~)
        handles.contrasthresh = source.Value;
        handles.hcontrasthreshtxt.String = {'Contrast';strjoin({'thresh:', num2str(round(handles.contrasthresh,2))})};
    end

    % set correlation threshold for the pipette pattern detection
    function pipmetric_callback(source,~)
        handles.pipmetricthresh = source.Value;
        handles.hcorrthreshtxt.String = {'Correlation';strjoin({'thresh:', num2str(round(handles.pipmetricthresh,2))})};
    end

    % set detection metric threshold, values are usually between (0,2)
    function beadmetric_callback(source,~)
        handles.beadmetricthresh = source.Value;
        handles.hmetrictxt.String = {'Metric'; strjoin({'thresh:', num2str(round(handles.beadmetricthresh,2))})};
    end

    % set circle detection gradient threshold
    function beadgrad_callback(source,~)
        handles.beadgradient = source.Value;
        handles.hgradtxt.String = {'Gradient: '; num2str(round(handles.beadgradient,2))};
    end
    
    % set circle detection sensitivity
    function beadsensitivity_callback(source,~)
        handles.beadsensitivity = source.Value;
        handles.hsensitivitytxt.String = {'Sensitivity: '; num2str(round(handles.beadsensitivity,2))};
    end
    
    % set bead tracking grace period
    function setbuffer_callback(source,~)
        val = str2double(source.String);
        if isnan(val) || val < 0
            warndlg({'The grace period must be a posivite number.';'Non-integer input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = num2str(handles.beadbuffer);
            return;
        end
        handles.beadbuffer = round(val);
        source.String = num2str(handles.beadbuffer);
    end

%% Runs bead detection and deduces bead radius range for tracking
    % get approximate range for MB radius interactively, in pixels
    function getradrange_callback(source,~,tag)
        
        % set selection lock
        if handles.selecting
            warn('select');
            return;
        else
            handles.selecting = true;
        end
        
        % detect the bead
        [beadinfo,pass,rad] = getBead(source,tag,'cbk',@getradrange_callback);
        source.String = '<HTML><center>Radius range</HTML>';    % restore button string
        
        if isempty(beadinfo) || ~pass   % check if selection was success
            handles.selecting = false;
            return; 
        end;        
        handles.hminrad.String = num2str(0.5*rad);              % set new radii
        handles.hmaxrad.String = num2str(1.5*rad);
        setrad_callback(0,0);
        handles.selecting = false;  % remove selection lock
 
    end

%% Set bead detection radius range
    % set limit on radius for the bead tracking; verify correct input
    function setrad_callback(~,~)
        vmin = str2double(handles.hminrad.String);
        vmax = str2double(handles.hmaxrad.String);
        if (isnan(vmin) || isnan(vmax) || vmin < 0 || vmax < 0 )     % abort if input is incorrect
            warndlg('Input must be a non-negative number of type double', 'Incorrect input', 'replace');
            handles.hminrad.String = num2str(handles.beadradius(1));
            handles.hmaxrad.String = num2str(handles.beadradius(2));
            return;
        end
        handles.beadradius(1) = vmin;
        handles.beadradius(2) = vmax;
        if (handles.beadradius(1) > handles.beadradius(2))  % warn if input gives empty range
            warndlg('Lower bead radius limit is larger than the upper limit',...
                'Empty radius range', 'replace');
        end
    end

%% Bead list functions
    % add the selected bead coordinate to list
    function addbead_callback(~,~)
        if isempty(handles.lastlistbead);
            warn('No bead to add.');
            return;
        end;
        handles.beadlist = strucopy(handles.beadlist,handles.lastlistbead);     % push back bead to the beadlist
        ind = numel(handles.beadlist);
        handles.hbeadinilist.String(ind) = {strcat('[',num2str(round(handles.lastlistbead.coor(1))),',',num2str(round(handles.lastlistbead.coor(2))),';',...
                                    num2str(handles.lastlistbead.frame),';',handles.lastlistbead.contrast,']')};
        handles.hbeadinilist.Value = ind;
    end

    % drop-down menu to choose one of the bead initial coors
    function pickbead_callback(source,~)
        val = source.Value;
        handles.bead = handles.beadlist(val);                
    end

    % remove selected bead coordinate from the list
    function rmbead_callback(~,~)
        val = handles.hbeadinilist.Value;
        num = numel(handles.beadlist);
        if (num == 0)
            return;
        elseif (num == 1)
            handles.hbeadinilist.String(1) = {'no data'};
            handles.hbeadinilist.Value = 1;
            handles.beadlist(num) = [];
        elseif (val == num)
            handles.hbeadinilist.String(val) = [];
            handles.beadlist(val) = [];
            handles.hbeadinilist.Value = val-1;
        else
            handles.hbeadinilist.String(val) = [];
            handles.beadlist(val) = [];
        end
    end

%% Pattern list functions
    % button adds current pattern to the pattern list
    function addpattern_callback(~,~)
        if isempty(handles.lastlistpat);
            warn('No pattern to add.');
            return;
        end;
        handles.patternlist = strucopy(handles.patternlist,handles.lastlistpat);    % adds new pattern to the end of the list
        ind = numel(handles.patternlist);
        handles.hpatternlist.String(ind) = {strcat('[',num2str(round(handles.lastlistpat.coor(1))),',',num2str(round(handles.lastlistpat.coor(2))),';',...
                                    num2str(handles.lastlistpat.frame),']')};
        handles.hpatternlist.Value = ind;
    end

    % button removes current pattern from the pattern list
    function rmpattern_callback(~,~)
       val = handles.hpatternlist.Value;
       num = numel(handles.patternlist);
       if (num == 0)    % case of nothing to remove
           return;
       elseif (num == 1)    % removing the last one; replace name with 'nodata'
           handles.hpatternlist.String(1) = {'no data'};
           handles.hpatternlist.Value = 1;
           handles.patternlist(val) = [];
       elseif (val == num)  % removing last entry in the list; shift left
           handles.hpatternlist.String(val) = [];
           handles.patternlist(val) = [];
           handles.hpatternlist.Value = val-1;
       else                 % general remove; shifts by itself
           handles.hpatternlist.String(val) = [];
           handles.patternlist(val) = [];
       end
    end
        
    % drop-down menu to choose one of the patterns
    function pickpattern_callback(source,~)
        val = source.Value;
        setpattern(handles.patternlist(val));                
    end

%% Detect bead in the frame as initial position for tracking
    % select the centre of the bead as a seed for tracking
    function getpoint_callback(source,~,srctag)
        
        % check if there's no other selection under way
        if handles.selecting
            warn('select');
            return;
        else
            handles.selecting = true;
        end
            
        [handles.bead,pass,~] = getBead(source,srctag);  % call method to detect bead
        
        % if detection fails (reject or error), old 'handles.bead' value is returned
        % if old value is empty, stop here, do not change anything
        if isempty(handles.bead) || ~pass; 
            handles.selecting = false;
            return; 
        end;  
            
        % only if meaningful handles.bead selection was returned, continue
        switch srctag
            case 'list'     % call source is list
                handles.lastlistbead = handles.bead;
                handles.hbeadcoortxt.String = strcat('[',num2str(round(handles.bead.coor(1))),',',num2str(round(handles.bead.coor(2))),...
                                        ';',num2str(handles.bead.frame),']');
            case 'interval' % call source is direct interval bead detection
                if (handles.interval.frames(1) ~= handles.bead.frame)
                    warn(strjoin({'Initial frame of current tracking interval was changed',...
                            'to the frame of bead selection. If You wish to preserve Your interval,',...
                            'reselect the bead in the appropriate frame.'}));
                    handles.interval.frames(1) = handles.bead.frame;
                    handles.hstartint.String = num2str(round(handles.interval.frames(1)));
                end;
                if (handles.interval.frames(2) == 0 || handles.interval.frames(2) < handles.interval.frames(1))
                    warn(strjoin({'Final frame of current tracking interval was invalid',...
                        'and was changed. The final frame must not precede the initial.'}));
                    handles.interval.frames(2) = handles.interval.frames(1);
                    handles.hendint.String = num2str(round(handles.interval.frames(2)));
                end;
                handles.interval.beadcoor = handles.bead.coor;
                handles.interval.contrast = handles.bead.contrast;
                handles.hbeadint.String = strcat('[',num2str(round(handles.interval.beadcoor(1))),',',num2str(round(handles.interval.beadcoor(2))),...
                                        ';',num2str(handles.interval.frames(1)),']');
                handles.tmpbeadframe = handles.interval.frames(1);
                handles.hgetpattern.Enable = 'on';
                handles.hselectpat.Enable = 'on';
        end
       
        handles.selecting = false;  % release detection lock
        
    end

%% Gets pattern for the pipette tip
    % allows user to select rectangular ROI as a pattern file
    function getrect_callback(source,~,srctag)
        
        % check if no other selection process is running
        if handles.selecting
            warn('select');
            return;
        else
            handles.selecting = true;
        end
        
        [handles.pattern,pass] = getPattern( source, srctag);
        
        if isempty(handles.pattern) || ~pass; 
            handles.selecting = false;
            return; 
        end;  
        
        switch srctag
            case 'list'
                handles.lastlistpat = handles.pattern;
                handles.hpatcoortxt.String = strcat( '[',num2str(round(handles.pattern.coor(1))),',',num2str(round(handles.pattern.coor(2))),';',...
                num2str(handles.pattern.frame),']');
                setpattern(handles.pattern);
            case 'interval'
                handles.interval.pattern = handles.pattern.cdata;
                handles.interval.patcoor = handles.pattern.coor;
                handles.tmppatframe = handles.pattern.frame;
                handles.updpatframe = 0;    % if pattern was matched to interval in the meantime, reset
                [handles.interval.reference,handles.interval.patsubcoor,~] = ...  % validate if the array is not already present
                    validatepattern(handles.pattern.cdata,handles.pattern.frame,handles.pattern.anchor);
                handles.hrefframe.String = num2str(handles.interval.reference);
                handles.hpatternint.String = strcat('[',num2str(round(handles.interval.patcoor(1))),',',num2str(round(handles.interval.patcoor(2))),...
                                        ';',num2str(handles.tmppatframe),']');
                handles.hpatsubcoor.String = strcat('[',num2str(round(handles.interval.patsubcoor(1))),','...
                                ,num2str(round(handles.interval.patsubcoor(2))),']');
        end
        
        handles.selecting = false;
                
    end

%% Get path of the video file
    % set video path by typing it in
    function videopath_callback(source,~)
        handles.videopath = source.String;
    end        

    % browse button to chose the file
    function [ validFile] = browsevideo_callback(~,~)
        [filename, pathname] = uigetfile({'*.avi;*.mp4;*.tiff;*tif','Video Files (*.avi,*.mp4,*.tiff)'},...
                                'Select a video file',handles.videopath);
        if ~isequal(filename, 0)     % test validity of selected file; returned 0 if canceled
            handles.videopath = strcat(pathname,filename);
            handles.hvideopath.String = handles.videopath;
            validFile = openvideo_callback; % returns true is properly openned
        else
            validFile = false;  % return not-selected flag
        end
    end

%% Settings for ouput video
    % sets frame rate of the output generated video
    function outvideo_callback(source,~,failsafe,var)
        val = round(str2double(source.String));
        if (isnan(val) || val < 1)
            warndlg('The input must be a positive number.','Incorrect input','replace');
            source.String = num2str(failsafe);
            return;
        end
        if (var == 1)
            handles.outframerate = val;
        elseif (var == 2)
            handles.outsampling = val;
        end
        
        source.String = num2str(val);   % in case of rounding
    end

    % generate an external video file of original film overlaid with
    % tracking marks
    function generatefilm_callback(~,~)
        BFPobj.generateTracks('Framerate',handles.outframerate,'Sampling',handles.outsampling);
    end

%% Display tracking overlay
    % whether to display or not the tracking data results
    function disptrack_callback(source,~)
        handles.disptrack = source.Value;
    end

%% Calculate (if not) and plot the video SD2 contrast
    % calculate SD2 contrast and plot the contrast progress of the video,
    % it can also be switched to rSD2 contrast, SD2 contrast is analyzed
    % and intervals of low contrast marked
    function getcontrast_callback(~,~,srctag)
        % if video is long, issue notice
        if vidObj.Frames > 1000 && handles.verbose && numel(vidObj.Contrast) ~= vidObj.Frames
            choice = questdlg(strjoin({'The video consists of more than 1000 frames. Depending on Your system,',...
                'the analysis can take up to several minutes. Progress is reported in the Matlab command window.',...
                'If successfully completed, the data could be later reused during tracking. Would You like to',...
                'continue?'}),'Contrast analysis', 'Continue', 'Cancel', 'Continue');
            switch choice
                case 'Continue' % continue with the analysis
                case 'Cancel'
                    return;     % cancel the analysis
            end
        end
        
        % if it is analysis call, take the whole domain
        if strcmp(srctag,'analysis')
            handles.lowplot = 1;                % initial frame
            handles.highplot = vidObj.Frames;   % final frame
            if handles.contype ~= 1 % switch to SD2 metric for analysis
                warn('Contrast metric type switched to SD2. There is no thresholding for rSD2 type metric');
                handles.contype  = 1;
                handles.hSD2.Value  = 1;
                handles.hrSD2.Value = 0;
            end
        end
        
        % returned 'contrast' all video frames, regardeless of subinterval
        % see function comment for details
        [ contrast, ~ ] = vidObj.getContrast(handles.lowplot, handles.highplot,handles.contype,backdoorObj.contrastRunningVarianceWindow);    
        if numel(contrast) ~= vidObj.Frames % if process of contrast calculation was cancelled
            handles.highplot = min(handles.lowplot+numel(contrast)-1, vidObj.Frames);
        end
        
        handles.fitInt = [handles.lowplot, 0; handles.highplot, 0];  % set global fit interval
        
        cla(handles.hgraph);                    % clear current graph
        ax2 = findobj('Tag','deformationaxis'); % delete the right y-axis, which might be...
        if exist('ax2','var'); ax2.delete; end; % ... drawn by force plotter; tagged
        hold(handles.hgraph,'on');
        set(handles.hgraph, 'FontUnits','normalized','FontSize',handles.labelfontsize);
        hconplot  = plot(handles.hgraph,handles.lowplot:handles.highplot,contrast(handles.lowplot:handles.highplot),'r','HitTest','off');
%        hgrayplot = plot(handles.hgraph,handles.lowplot:handles.highplot,gray(handles.lowplot:handles.highplot), 'b', 'HitTest','off');
        xlim(handles.hgraph,[handles.lowplot,handles.highplot]);    % avoid margins around the graph
        handles.thisRange = [handles.lowplot,handles.highplot];     % range of the current plot
        handles.thisPlot = 1;                       % currently plotted contrast flag
        handles.hgraphplot.Enable = 'on';           % allow plot button, contrast only
        set( handles.hlowplot,  'Enable','on', 'String', num2str(handles.lowplot)  );
        set( handles.hhighplot, 'Enable','on', 'String', num2str(handles.highplot) );        
%        legend(handles.hgraph,'contrast','mean gray');
        cl = legend(handles.hgraph,'contrast');
        cl.Box = 'off';
        cl.FontUnits = 'normalized';
        title(handles.hgraph,{'Contrast measure';'[standard deviation of each frame]'},'Color','r','FontUnits','normalized','FontSize',handles.labelfontsize);
        xlabel(handles.hgraph, 'Time [frames]', 'FontUnits', 'normalized', 'FontSize', handles.labelfontsize);
        ylabel(handles.hgraph, 'Contrast [r.u.]', 'FontUnits', 'normalized', 'FontSize', handles.labelfontsize);
        
        % find plateaux and report 'safe' and 'unsafe' intervals
        % these parameters can be backdoored;
        % sensitivity, threshold, duration and minimal contrast. The results are only
        % informative, so user should need to change them. More
        % sophisticated analysis can be done using adaptive plateaux
        % fitting.
        if strcmp(srctag,'analysis')    % if the call comes from analysis
            
            % save default values suitable for force plateaux detection
            defaults = [ handles.kernelWidth, handles.noiseThresh, handles.minLength ];

            handles.kernelWidth = backdoorObj.contrastPlateauDetectionSensitivity;
            handles.noiseThresh = backdoorObj.contrastPlateauDetectionThreshold;
            handles.minLength   = backdoorObj.contrastPlateauDetectionLength;

            fit_callback(0,0,'plat',true);

            % restore defaults
            [handles.kernelWidth] = defaults(1);
            [handles.noiseThresh] = defaults(2);
            [handles.minLength]   = defaults(3);

            if handles.verbose;
                helpdlg(strjoin({'Contrast analysis has finished. The detected plateaux (in red) are the safest',...
                    'intervals for tracking. Drop in contrast of more than',num2str((1-backdoorObj.contrastPlateauDetectionLimit)*100),'%',...
                    'off maximum is designated (if detected) in blue. Those intervals might be unsuitable for tracking.'}),...
                    'Contrast analysis finished');
            end
        end
        
        handles.hgraph.ButtonDownFcn = {@getcursor_callback};
    end

%% Go to frame
    % sets frame input into edit field after pressing a button
    function gotoframe_callback(~,~)
        % temporary edit field
        hsetframe = uicontrol('Parent',handles.husevideo, 'Style','edit', 'Units', 'normalized','FontUnits','normalized',...
             'Position', [0.8, 0.75, 0.2, 0.25],'String',num2str(getFrame()),'Callback', {@presetframe});

        % avoid errors; treat malformed input
        function presetframe(src,~)
            val = str2double(src.String);
            if isnan(val)
            elseif val <= 0
                setframe(1);
            elseif val >= vidObj.Frames
                setframe(vidObj.Frames);
            else
                setframe(val);
            end
            delete(hsetframe);  % delete the edit field
        end
    end

%% Video playback functions
    % rewinds or fast forwards video; argument sense is usually +/-5 frames
    % but the value can be changed in backdoorObj
    function fastvideo_callback(~,~,sense)
        if sense < 0
            sense = backdoorObj.rewindFramerate;
        else
            sense = backdoorObj.fastforwardFramerate;
        end
        playvideo_callback(0,0,sense);
    end    
         
    % starts to play the video
    function playvideo_callback(~,~,rate)
        handles.playing = true;
        handles.hplaybutton.String = 'Stop';
        handles.hplaybutton.Callback = {@stopvideo_callback};
        while ((vidObj.CurrentFrame + rate <= vidObj.Frames && vidObj.CurrentFrame + rate > 0) && handles.playing)
            setframe(vidObj.CurrentFrame+rate);     
            pause(1);
        end        
        handles.hplaybutton.String = 'Play';

    end

    % stops the video play
    function stopvideo_callback(~,~)
        handles.playing = false;
        handles.hplaybutton.String = 'Play';
        handles.hplaybutton.Callback = {@playvideo_callback,1}; % restores play callback, sets framerate to 1
    end

%% Open video defined by path
    % open video and set its parameters where necessary; update callbacks
    function [newOpenned] = openvideo_callback(~,~)
        newOpenned = false;
        if exist(handles.videopath,'file') ~= 2;    % i.e. path is not a path to a file
            warndlg('Path is incorrect or the file doesn''t exist','File inaccessible','replace');
            return;
        else
            try
                vidObj = vidWrap(handles.videopath);
                handles.frame = struct('cdata', zeros(vidObj.Height,vidObj.Width, 'uint16'), 'colormap', []);
                handles.hmoviebar.Enable = 'on';
                handles.hmoviebar.Min = 1;
                handles.hmoviebar.Max = vidObj.Frames;
                handles.hmoviebar.Value = vidObj.CurrentFrame;
                handles.hmoviebar.SliderStep = [ 1/vidObj.Frames, 0.1 ];
                setframe(1);
                setvidinfo();
                handles.interval = struct('frames', [1,1],'pattern',[]);    % reset interval-in-making
                handles.interval.frames = [1,vidObj.Frames];    % set initial interval and callback parameters
                set(handles.hstartint, 'String', num2str(handles.interval.frames(1)),...
                    'Callback',{@setintrange_callback,handles.interval.frames(1),1});
                set(handles.hendint, 'String', num2str(handles.interval.frames(2)),...
                    'Callback',{@setintrange_callback,handles.interval.frames(2),2});
                handles.hrefframe.String = [];
                handles.hpatsubcoor.String = '[.,.]';
                set([handles.hpatternint,handles.hbeadint],'String','[.,.;.]');
                set([handles.hgetbead, handles.hselectbead],'Enable','on'); % enable selections
                set([handles.hdispframe,handles.hstartint,handles.hendint,handles.hshowframe,handles.hrefframe],'Enable','on');
                set([handles.hplaybutton,handles.hrewindbtn,handles.hffwdbutton,handles.hcontrast],'Enable','on');
                handles.hradtxt.Enable = 'on';
                handles.haddinterval.Enable = 'off';
                handles.hvideopath.String = handles.videopath;  % if called without GUI (i.e. the path string not updated)
                newOpenned = true;
            catch
                % issue warning of incompatible file
                warndlg(strjoin({'The specified file at', handles.videopath, 'exists, but could not be openned.',char(10),...
                     'It is either malformed or its format is invalid. Please check the file and try again.'}),...
                     'Invalid video file','replace');
                % restore currently active videopath, if not empty
                if ~isempty(vidObj)
                    handles.videopath = vidObj.videopath;
                    handles.hvideopath.String = handles.videopath;
                end
            end
            % this is run separately, to have fallback values in case the
            % user cancels the dialog or does something unexpected, the try
            % fails and the video doesn't open at all
            if ~isempty(vidObj) || newOpenned     % a new object was successfully created
                if vidObj.istiff    % from a TIFF file
                    hfrd = vidObj.getFramerate();   % querry to obtain FR
                    uiwait(hfrd);
                    handles.hvidframerate.String = strcat('Framerate: ',num2str(vidObj.Framerate), ' fps');
                    handles.hvidduration.String = strcat('Duration: ',num2str(vidObj.Duration),' s');
                end
            end
        end
    end

    % set position in the video
    function videoslider_callback(source,~)
        setframe(source.Value);
    end
% ==================================================================
%%   ======================== HELPER FUNCTIONS ==========================

%% Extract the pipette pattern from the frame
    % detect and return pipette pattern based on the selected area;
    % try/catch in case user interrupts the selection
    function [ patinfo,pass ] = getPattern( source, tag )
        
        patinfo = struct('coor',[],'frame',[],'reference',[], 'cdata', [], 'anchor', []);
        BCRfunction = makeConstrainToRectFcn('imrect',handles.haxes.XLim,handles.haxes.YLim);
        rectangle = imrect(handles.haxes,'PositionConstraintFcn',BCRfunction);              % interactive ROI selection
        source.String = 'Confirm';         % update UI to confirm selection
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);   
        
        try 
            dcoor = rectangle.getPosition;  % vector of 4 coordinates; doubles
            icoor = round(dcoor);
            roi = [ max(icoor(2),1), min(icoor(2)+icoor(4),vidObj.Height);...       % ROI in the image
                    max(icoor(1),1), min(icoor(1)+icoor(3),vidObj.Width) ];         % construct coors of ROI
            patinfo.cdata = handles.frame.cdata(roi(1,1):roi(1,2),roi(2,1):roi(2,2),:);   % copy the selected image  
            patinfo.coor = [ dcoor(1), dcoor(2) ];          % save rect upper left corner
            patinfo.frame = round(vidObj.CurrentFrame);     % set reference distance for the pattern
            
            rectangle.delete;
            
            choice = questdlg(strjoin({'Please, select the anchor on the pattern, keep default selection.',...
                             'For more information, choose ''Info'' button'}),'Anchor selection',...
                             'Select', 'Default', 'Info', 'Default');
                         
            if strcmp(choice,'Info')
                choice = questdlg(strjoin({'The anchor represents a coordinate on the pattern, which',...
                        'will be reported by the tracking method over time. It determines the point on the',...
                        'pipette, which will be used to calculate the extension of the red blood cell.',...
                        'You can select the point Yourself, or let the choice up to algorithm.'}),...
                        'Anchor selection - details', 'Select', 'Default', 'Default');
            end
            
            switch choice
                case 'Select'

                    % set depending on the source call
                    if strcmp(tag,'interval')
                        handles.interval.pattern = patinfo.cdata;
                        [hf,hax] = showintpattern_callback();
                    else
                        hax = handles.hminiaxes;
                        imagesc(patinfo.cdata, 'Parent', hax);  % display the cut in the special window
                        axis(hax, 'image','off');
                    end
                    
                    BCfunction = makeConstrainToRectFcn('impoint',get(hax,'XLim'),get(hax,'YLim'));
                    anchorpoint = impoint(hax, 'PositionConstraintFcn', BCfunction);
                    source.String = 'Accept';
                    source.ForegroundColor = 'red';
                    source.Callback = 'uiresume(gcbf)';
                    uiwait(gcbf);
                    try
                        patinfo.anchor = anchorpoint.getPosition;                        
                    catch
                        warning(strjoin({'An error occured during anchor selection callback,',...
                        'it was probably interrupted by another function or action.'}));
                        warndlg({'Selection function failed. The anchor point value (reference) has been set to default';...
                            'It can still be modified in Interval selection window.'},'Anchor selection failed','replace');
                        patinfo.anchor = round(0.5*[size(patinfo.cdata,2),size(patinfo.cdata,1)]);
                    end
                    set(source, 'String', 'Select', 'ForegroundColor', 'black', 'Callback',  {@getrect_callback,tag});
                    anchorpoint.delete;
                    if exist('hf','var'); hf.delete; end;
                case 'Default'
                    patinfo.anchor = round(0.5*[size(patinfo.cdata,2),size(patinfo.cdata,1)]);
            end

            if strcmp(tag,'interval')
                handles.hgetpatsubcoor.Enable = 'on';
                handles.hshowpattern.Enable = 'on';
                handles.haddinterval.Enable = 'on';
                handles.hgetrefframe.Enable = 'on';
            end
            pass = true;
            
        catch
            warn('interrupt');
            rectangle.delete;
            patinfo = handles.pattern;
            pass = false;
            
        end
        
        source.String = 'Select';
        source.Callback = {@getrect_callback, tag};
        
    end

%% Detect the bead near the click-provided coordinate
    % detect and return bead information; calls TrackBead method; provides
    % also bead detection radius range calibration
    function [ beadinfo,pass,rad ] = getBead( source,tag, varargin )
        
        persistent inpar;   % persistent parser, created only once
        
        % create parser instance, if not present
        if isempty(inpar)            
            inpar = inputParser();
            defaultAxHandle = handles.haxes;    % default axes are main figure axes
            defaultFrame    = vidObj.CurrentFrame;
            defaultCallback = @getpoint_callback;   % to reset source cbk

            inpar.addRequired('source');    % calling uicontrol
            inpar.addRequired('tag');       % call from list or direct
            inpar.addParameter('hax', defaultAxHandle, @isgraphics);
            inpar.addParameter('frm', defaultFrame, @isfloat);
            inpar.addParameter('cbk', defaultCallback );
        end
        
        % parse the inputs (they should allow overloads in Matlab...)
        inpar.parse(source,tag,varargin{:});
        
        source = inpar.Results.source;
        tag = inpar.Results.tag;
        hax = inpar.Results.hax;
        frm = round(inpar.Results.frm);
        cbk = inpar.Results.cbk;
        % =============================================================
        
        beadinfo = struct('coor',[],'frame',[],'contrast',[]);
        % intial section, set boundary, select point, change UI, wait for
        % confirmation of the selection
        BCfunction = makeConstrainToRectFcn('impoint',get(hax,'XLim'),get(hax,'YLim'));
        beadpoint = impoint(hax,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        
         try
            beadinfo.coor = beadpoint.getPosition;
            beadinfo.frame= round(frm);
            choice = questdlg('Select bead contrast. For a bead darker than background, select ''Dark'', and visa versa.',...
                'Bead contrast','Bright','Dark','Dark');
            switch choice
                case 'Bright'
                    beadinfo.contrast = 'bright';
                case 'Dark'
                    beadinfo.contrast = 'dark';
            end;
            beadpoint.delete;
            
            if strcmp(tag,'beadrad')      
                defaultRad = [5,50];    % wide range to catch-all (nearly)
            else
                defaultRad = handles.beadradius;
            end

            [coor,rad,metric,~] = TrackBead(vidObj, beadinfo.contrast, beadinfo.coor,...
                         [ beadinfo.frame, beadinfo.frame ], 'radius', defaultRad, 'retries', 1 );  % try to detect the bead in the frame

            if rad == 0;    % stop if nothing is detected
                warndlg(strjoin({'No bead was detected in the given vicinity for',beadinfo.contrast,'contrast.',...
                    'Please repeat Your selection, placing the search point within the desired bead',...
                    'and choosing the appropriate contrast. Search will now abort.'}),'No bead detected','replace');
                pass = false;
                source.String = 'Select';
                source.Callback = {cbk,tag};
                return;     % kill the procedure
            end
                
            if metric < handles.beadmetricthresh;   % warn for weak detection; use glob metric thresh
                    warn(strjoin({'The bead metric is only',num2str(metric),...
                    'which is below the threshold',num2str(handles.beadmetricthresh),...
                    'and detection failures can occur.'}));
            end;
                
            hcirc = viscircles(hax,[ coor(2), coor(1) ], rad, 'EdgeColor','r');    % plot the detected bead
            choice = questdlg('Was the bead detected correctly?','Confirm selection','Accept','Reject','Accept');
            switch choice
                case 'Accept'   % precise the coordinate
                    beadinfo.coor = [coor(2), coor(1) ];
                    pass = true;
                case 'Reject'
                    beadinfo = handles.bead;
                    pass = false;
            end;
            hcirc.delete;
        catch
            warn('interrupt');
            beadpoint.delete;
            beadinfo = handles.bead;
            pass=false;
            rad = 0;
        end
        
        source.String = 'Select';
        source.Callback = {cbk,tag};                     
                     
    end

%% Select and display pattern from the list
    % selects pattern
    function [] = setpattern(pattern_in)
       handles.pattern = pattern_in;
       imagesc(handles.pattern.cdata, 'Parent', handles.hminiaxes);  % display the cut in the special window
       axis(handles.hminiaxes, 'image','off');    
    end

%% Small video procedures
    % returns current frame number; can be changed to more complex and
    % failsafe behaviour (now's just ridiculous, I know)
    function [currentFrame] = getFrame()
        currentFrame = handles.vidFrameNo;
    end

    % check if this frame is part of the video
    function [ is ] = isinvideo(frame)
        is = ( frame > 0 && frame <= vidObj.Frames );
    end

%% Set requested frame number as current frame
    % sets the GUI to the given frame number; takes case of drawing the
    % detection overlay, if requested
    function [] = setframe(frameNo)
        handles.vidFrameNo = round(frameNo);
        handles.frame = vidObj.readFrame(handles.vidFrameNo);
        handles.hdispframe.String = strcat(num2str(handles.vidFrameNo),'/', num2str(vidObj.Frames));
        handles.hmoviebar.Value = vidObj.CurrentFrame;        
        imagesc(handles.frame.cdata, 'Parent', handles.haxes);
        colormap(gray);        
        axis(handles.haxes, 'image');               % set limits of the canvas to 'image'
        handles.haxes.FontUnits = 'normalized';     % make sure ticks are rescaled with the window
        if handles.disptrack
            hold(handles.haxes, 'on')
            for i=1:numel(BFPobj.intervallist);
                if( handles.vidFrameNo >= BFPobj.intervallist(i).frames(1) && ...
                    handles.vidFrameNo <= BFPobj.intervallist(i).frames(2) )
                    coorind = handles.vidFrameNo - BFPobj.intervallist(i).frames(1) + 1;
                    viscircles(handles.haxes,[ BFPobj.pipPositions(i).coor(coorind,2)/handles.P2M,... 
                                       BFPobj.pipPositions(i).coor(coorind,1)/handles.P2M ],...
                               5, 'EdgeColor','b');   % plot pipette
                    viscircles(handles.haxes,[ BFPobj.beadPositions(i).coor(coorind,2)/handles.P2M,... 
                                       BFPobj.beadPositions(i).coor(coorind,1)/handles.P2M ],...
                               BFPobj.beadPositions(i).rad(coorind)/handles.P2M, 'EdgeColor','r');  % plot bead
                    break; % do not continue once plotted
                end
            end
        end
    end

%% Video information report
    % populates the video information pannel
    function setvidinfo()
        handles.hvidwidth.String = strcat('Width: ',num2str(vidObj.Width),' px');
        handles.hvidheight.String = strcat('Height: ',num2str(vidObj.Height),' px');
        handles.hvidframes.String = strcat('Frames: ',num2str(vidObj.Frames));
        handles.hvidname.String = strcat('Name: ', vidObj.Name);
        handles.hvidformat.String = strcat('Format: ', vidObj.Format);
        if ~vidObj.istiff
            handles.hvidframerate.String = strcat('Framerate: ',num2str(vidObj.Framerate), ' fps');
            handles.hvidduration.String = strcat('Duration: ',num2str(vidObj.Duration),' s');
        end
    end

%% Copy strcture   
    % copy structure into an empty target
    function outlist = strucopy(outlist,item)
        size = numel(outlist);
        names = fieldnames(item);
        for i=1:numel(names)
            outlist(size+1).(names{i}) = item.(names{i});
        end
    end
    
%% Validate new pip pattern against already present patterns
    % search if the current pattern is already present in the list and user
    % appropriate reference frame and anchor, if it is
    % in: pattern: the image array; patframe: the frame of origin of image,
    % anchor: selected anchor of the image pattern
    function [rframe,ranchor,absent] = validatepattern(pattern,patframe,anchor,nowarn)
        if ~exist('nowarn','var'); nowarn = false; end;
        rframe  = patframe;     % return zero, if original reference cannot be found
        ranchor = anchor;
        absent  = true;
        if numel(handles.intervallist) > 0        
            for i=1:numel(handles.intervallist)
                if isequaln(pattern, handles.intervallist(i).pattern)
                    if (rframe == handles.intervallist(i).reference) && all(ranchor == handles.intervallist(i).patsubcoor)
                        if ~nowarn
                            warn(strjoin({'The pattern was recognised in another interval,',...
                                'all settings comply.'}));
                        end
                    else
                        rframe   = handles.intervallist(i).reference;    % this is the reference distance frame
                        ranchor  = handles.intervallist(i).patsubcoor;   % this is the anchor for the given pattern
                        if ~nowarn
                            warn(strjoin({'The pattern was found in another present interval',...
                                'and reference frame and anchor point were updated accordingly.',char(10),...
                                strcat('Reference frame reset to:',num2str(rframe)),char(10),...
                                strcat('Anchor point reset to:[',...
                                num2str(round(ranchor(1))),',',num2str(round(ranchor(2))),']'),char(10),...
                                'You can change this manually, in the interval selection panel.'}));
                        end
                    end
                    absent = false;
                    break;
                else
                    absent = true;
                    % old values are returned, if pattern is not found
                end
            end
        else
            % do nothing
        end
    end

%% Generate table with intervals
    % generates table of intervals from the intervallist entries
    function makeTab()
        
        tablist = struct2table(handles.intervallist,'AsArray',true);    % convert structure to table, so that certain fields can be safely removed from the displayed table
        tablist.pattern = [];                                   % remove the pattern images
        tablist.contrast = [];                                  % remove contrast string
        tablist.reference = [];                                 % remove reference frame
        inArray = table2array((tablist));                       % convert table to array of doubles, so that the fields are separated into unity width columns
        inArray = round(inArray);                               % round, just to make things look nicer and optimize space
        
        removes = num2cell(false(numel(handles.intervallist),1));       % column of selectable fields to allow removals; cell array
        inData = num2cell(inArray);                             % convert the numeric inputs into cell array (that's what uitable wants)
        inData(:,size(inArray,2)+1) = removes;                  % combine the cell arrays and choke the shrew
        
        htab = uitable('Parent', handles.hlistinterval,'Data', inData, 'ColumnName', colnames, 'ColumnFormat',...
               colformat, 'ColumnEditable',[false false false false false false false false true],...
               'RowName',[], 'Units','normalized','Position',[0,0,0.9,1],...
               'ColumnWidth',{52},'CellEditCallback',@rmtabledint_callback);
    end

%% Contrast type radiobutton switch
    % radio button group selection change callback
    % determines which type of contrast will be plot
    function contype_callback(~,data)
        if data.NewValue == handles.hSD2;
            handles.contype = 1;    % plot SD2 contrast metric
            disp('Contrast plot set to SD2 metric');
        else
            handles.contype = 2;    % plot running contrast metric
            disp('Contrast plot set to rSD2 metric');
        end
        
        % if contrast plot is and will be open; replot when changed type
        if ~isempty(handles.thisPlot) && handles.thisPlot == 1 && handles.toPlot==1
            graphplot_callback(0,0);
        end                
    end

%% Exponential fit of graphed data
    % fits data with one-parametric exponentiel
    function [ est, FitCurve ] = expfit( int, frc, varargin )
            
            persistent inp;
    
            % create the parser, if doesn't exist
            if isempty(inp)
                inp = inputParser();
                defaultRate = 1;

                addRequired(inp, 'int');
                addRequired(inp, 'frc');
                addParameter(inp, 'framerate', defaultRate, @isnumeric);
            end;
            
            % parse the inputs
            inp.parse(int, frc, varargin{:});
            
            int = inp.Results.int;
            frc = inp.Results.frc;
            rate = inp.Results.framerate;
            % ===============================
        
            DF = frc(end) - frc(1);     % change in force
            int = (int - int(1))/rate;  % start time at 0
            
            initau = 1;                 % initial time constant guess
            model = @expfun;            % model exp function handle
            options = optimset('Display','final','FunValCheck','on');
            est = fminsearch(model, initau, options);            
            
            function [sse, fittedCurve] = expfun(tau)
                fittedCurve = frc(1) + DF * ( 1.0 - exp(-int/tau) );
                errorVector = fittedCurve - frc;
                sse = sum(errorVector.^2);
            end
            
            [~, FitCurve] = model(est);
    end 

%% Generate valid name of file to save data/image/figure
    % function to set up path for a file to save
    function [ exportfile ] = putFileName(name)
        dataList = { '.csv','.txt','.dat' };
        graphicList = { '.bmp','.eps','.jpg', '.pdf','.png','.tif','.fig' };
        matFile = '.mat';
        persistent dir;
        if isempty(dir)
            if ~isempty(vidObj)
                [dir, ~, ~ ] = fileparts(vidObj.videopath); % the same dir as video to start
            else
                dir = pwd;
            end
        end
        inipath = fullfile(dir,name);
        [~,~,ext] = fileparts(inipath);
        switch ext
            case dataList
                [filename, dir] = uiputfile({'*.csv;*.txt;*.dat;','Data files (*.csv,*.txt,*.dat)'},...
                                'Select a file for export',inipath);    % choose path and file for data export
            case graphicList
                [filename, dir] = uiputfile({'*.bmp;*.eps;*.jpg;*.pdf;*.png;*.tif;*.fig','Data files (*.bmp,*.eps,*.jpg,*.pdf,*.png,*.tif,*.fig)'},...
                                'Select a file for export',inipath);    % choose path and file for graphic export
            case matFile
                [filename, dir] = uiputfile({'*.mat;','Mat-files (*.mat)'},...
                                'Select a file for export',inipath);    % choose path and file for matlab export
        end
        if isequal(filename,0) || isequal(dir,0)
            exportfile = 0;
            dir = pwd;
        else
            exportfile = fullfile(dir,filename);
        end
    end

%% Get valid name and path of file to load data
    % function to set up path for a file to load
    function [importfile] = getFileName(name)
        dataList = { '.csv','.txt','.dat' };
        graphicList = { '.bmp','.eps','.jpg', '.pdf','.png','.tif','.fig' };
        matFile = '.mat';
        persistent dir;
        if isempty(dir)
            if ~isempty(vidObj)    % if object was instantiated
                [dir, ~, ~ ] = fileparts(vidObj.videopath); % the same dir as video to start
            else
                dir = pwd;
            end
        end
        inipath = fullfile(dir,name);
        [~,~,ext] = fileparts(inipath);
        switch ext
            case dataList
                [filename, dir] = uigetfile({'*.csv;*.txt;*.dat;','Data files (*.csv,*.txt,*.dat)'},...
                                'Select a file for import',inipath);    % choose path and file for data export
            case graphicList
                [filename, dir] = uigetfile({'*.bmp;*.eps;*.jpg;*.pdf;*.png;*.tif;*.fig','Data files (*.bmp,*.eps,*.jpg,*.pdf,*.png,*.tif,*.fig)'},...
                                'Select a file for import',inipath);    % choose path and file for graphic export
            case matFile
                [filename, dir] = uigetfile({'*.mat;','Mat-files (*.mat)'},...
                                'Select a file for import',inipath);    % choose path and file for matlab export
        end
        importfile = fullfile(dir,filename);
        
    end

%% Warning function
    % function to display warning dialogue or just command line warning,
    % depending on the 'handles.verbose' variable; Some warning messages are preset
    % otherwise, the passed string is displayed
    function warn( type, append )
        
        % construct the string
        switch type
            case 'select'
                str = 'Another selection process is currently running. Finish the former and try again.';
                name = 'Concurrent selection';
            case 'interrupt'
                str = strjoin({'Selection process was interrupted by another action.',...
                'Please try again, without any intermittent action during the process.'});
                name = 'Interrupted selection';
            otherwise
                str = type;
                name = 'Specific warning';
        end
        
        if exist('append','var');
            strParts = {str,append};
            str = strjoin(strParts,'\n\n');   % construct two-part warning
        end;
       
        % display either the warining dialogue or command line warning
        if handles.verbose
            hdia = warndlg(str, name, 'replace');
            uiwait(hdia);
        else
            warning(str);
        end            
        
    end

%% Plot horizontal line of zero load/deformation
    % plots red dashed line at y=0 to indicate pushing and pulling
    function plotZeroLine()
        handles.hzeroline = plot(handles.hgraph,handles.lowplot:handles.highplot,zeros(1,handles.highplot-handles.lowplot+1),...
                     '--r','LineWidth',2,'HitTest','off');
        handles.pushtxt = text(handles.hgraph.XLim(2),0,'Pushing','Parent',handles.hgraph,'FontUnits','normalized',...
            'HorizontalAlignment','right', 'VerticalAlignment','top','Color','red',...
            'FontSize',handles.labelfontsize,'Margin',5,'HitTest','off');
        handles.pulltxt = text(handles.hgraph.XLim(2),0,'Pulling','Parent',handles.hgraph,'FontUnits','normalized',...
            'HorizontalAlignment','right', 'VerticalAlignment','bottom','Color','red',...
            'FontSize',handles.labelfontsize,'Margin',5,'HitTest','off');
    end

%% RBC stiffness annotation
    % generates RBC stiffness annotation after the force was run
    function makeStiffAnot()
        if isempty(BFPobj)||isempty(BFPobj.k)
            warn('RBC stiffness information can be generated only after the force has been calculated');
            return;
        end;
        persistent hanot;
        if ~isempty(hanot);hanot.delete;end;
        if handles.overLimit;colour = 'red'; else colour = 'blue';end
        strk = {strcat('$$ k = ', num2str(round(handles.stiffness)),' \frac{pN}{\mu m}$$'),...
               strcat('$$ \Delta k = \pm' , num2str(round(BFPobj.Dk)),' \frac{pN}{\mu m} $$')};
        hanot = annotation( handles.hcalc, 'textbox', 'interpreter', 'latex', 'String', strk, ...
            'Units', 'normalized', 'Position', [0,0.67,0.5,0.15], 'Margin', 0, ...
            'LineStyle','none','FitBoxToText','off','Color',colour,'FontUnits','normalized');
    end

%% Export the whole environment
    function saveEnvironment(fileName)
        % GUI settings
        for dat = 1:numel(GUIdata)
            outgoing.GUIdata.(GUIdata{dat}) = handles.(GUIdata{dat});
        end
        
        % objects
        outgoing.GUIobj.backdoorObj = backdoorObj;
        outgoing.GUIobj.BFPobj = BFPobj;        
        outgoing.GUIobj.vidObj = vidObj;
        
        % GUI flags
        % strings
        for str = 1:numel(GUIflags.Strings)
            outgoing.GUIflags.(GUIflags.Strings{str}).String = handles.(GUIflags.Strings{str}).String;
        end
        % values
        for val = 1:numel(GUIflags.Values)
            outgoing.GUIflags.(GUIflags.Values{val}).Value = handles.(GUIflags.Values{val}).Value;
        end
        % enables
        for ebl = 1:numel(GUIflags.Enables)
            outgoing.GUIflags.(GUIflags.Enables{ebl}).Enable = handles.(GUIflags.Enables{ebl}).Enable;
        end
        % visibility
        for vis = 1:numel(GUIflags.Visibles)
            outgoing.GUIflags.(GUIflags.Visibles{vis}).Visible = handles.(GUIflags.Visibles{vis}).Visible;
        end
        
        save(fileName,'outgoing');
    end

%% Load a full saved session from a file
    function loadEnvironment(fileName)
        
        in = load(fileName);
        
        oldvideopath = handles.videopath;
        oldvidobj = vidObj;     % [] if empty
        handles.videopath = in.outgoing.GUIdata.videopath;
        
        % open video -- sets up GUI values, which will be later modified
        % generates vidObj object, the video wrapper, based on the imported
        % video information; 
        % if the video file doesn't exist or it cannot be successfully
        % opened, user can navigate to the proper file, if it fails as
        % well, import is interrupted
        if exist(handles.videopath,'file') ~= 2 || ~openvideo_callback();    % i.e. path is not a path to a file or openning fails
            hwd = warndlg('Path to the video file is incorrect, the file doesn''t exist or is malformed. Please try to navigate to the appropriate file.',...
                'File not found','replace');   
            validFile = browsevideo_callback(); % attempt to browse and open the video
            if ~validFile   % no valid video provided
                handles.videopath = oldvideopath;   % restore old videopath
                return;                             % if import failed, return
            end
            hwd.delete;
        end
        
        % generate matching structure
        match = vidObj.matchVideos(in.outgoing.GUIobj.vidObj);     % test if videos seem the same (just verify width,height,#frames,format)
        
        % inform if videos match; copy calculated data if they do
        if ~match.result
            warndlg(strjoin({'The specified video doesn''t match the imported video. The matching procedure',...
                'reported the following results:',char(10), 'width:', num2str(match.width), char(10),...
                'height:',num2str(match.height), char(10), '#frames:', num2str(match.frames),  char(10),...
                'format:',num2str(match.format), char(10), ...
                'The former video will be reinstated (if any), and import will terminate'}));
            vidObj = oldvidobj;                         
            handles.videopath = oldvideopath;
            handles.hvideopath.String = oldvideopath;
        else
            disp('The dimensions, format and frames# matches, importing contrast data.');
            vidObj.Contrast     = in.outgoing.GUIobj.vidObj.Contrast;
            vidObj.GrayLvl      = in.outgoing.GUIobj.vidObj.GrayLvl;
            vidObj.LocContrast  = in.outgoing.GUIobj.vidObj.LocContrast;
            vidObj.Duration     = in.outgoing.GUIobj.vidObj.Duration;
            vidObj.Framerate    = in.outgoing.GUIobj.vidObj.Framerate;
        end
        
        backdoorObj = BFPGUIbackdoor(@backdoorFunction);    % preconstruct object connected to bd-function
        BFPobj = [];    % preconstruct empty object
        
        % GUI data
        for elm = 1:numel(GUIdata)
            handles.(GUIdata{elm}) = in.outgoing.GUIdata.(GUIdata{elm});
        end
        
        makeTab();                  % generates tab of selected intervals
        handles.selecting = false;  % selection processes are not imported
        handles.playing = false;    % video loaded in stopped state
        
        % GUI flags
        for elm = 1:numel(GUIflags.Enables)
            handles.(GUIflags.Enables{elm}).Enable =  in.outgoing.GUIflags.(GUIflags.Enables{elm}).Enable;
        end 
        for elm = 1:numel(GUIflags.Strings)
            handles.(GUIflags.Strings{elm}).String = in.outgoing.GUIflags.(GUIflags.Strings{elm}).String;
        end 
        for elm = 1:numel(GUIflags.Values)
            handles.(GUIflags.Values{elm}).Value = in.outgoing.GUIflags.(GUIflags.Values{elm}).Value;
        end   
        for elm = 1:numel(GUIflags.Visibles)
            handles.(GUIflags.Visibles{elm}).Visible = in.outgoing.GUIflags.(GUIflags.Visibles{elm}).Visible;
        end           

        % objects
        %vidObj = in.outgoing.GUIobj.vidObj;    % object already duplicated
        BFPobj = in.outgoing.GUIobj.BFPobj;
        backdoorObj = in.outgoing.GUIobj.backdoorObj;
        
        % generate stiffness annotation
        if ~isempty(BFPobj) && ~isempty(BFPobj.k); makeStiffAnot(); end;

        
    end

%   ====================================================================
%%   ============== SINGLE-FRAME CALIBRATION FUNCTIONS =================    
%   The single frame calibration is necessary, if the reference distance
%   frame (i.e. the frame, where the bead and the RBC just touch, with zero
%   load incurred on the bead) is not part of any tracked interval. Then,
%   the program attempts to semi-automatically create and add single-frame
%   interval. User only needs to verify the pipette pattern was well
%   matched and select the appropriate bead (in case more beads are
%   present).

%% Create new figure, where user can calibrate the probe
    % constructs the calibration figure, uicontrols etc.
    function [hcalibfig]= buildCalibFig()
        
        % build the controls
        titstr = strjoin({'Calibration single-frame interval - frame',num2str(handles.calibint.reference)});
        hcalibfig   = figure('Name', titstr,'Units', 'normalized','WindowStyle','modal',...
            'OuterPosition', [0.2,0.2,0.6,0.6], 'Visible', 'on', 'Selected', 'on',...
            'CloseRequestFcn',{@calibfigCleanup_closereq});
        hcalibax    = axes('Parent',hcalibfig,'Units','normalized', 'Position', [0,0.3,1,0.6],...
         'FontUnits','normalized');
        hacceptpip  = uicontrol('Parent', hcalibfig,'Style','pushbutton', ...
         'Units', 'normalized', 'Position', [0.05,0.1,0.2,0.1],'FontUnits','normalized',...
         'TooltipString','Accept pipette detection to finalise calibration',...
         'String', '<HTML><center> Accept <br> Pipette </HTML>','Interruptible','on',...
         'Callback', {@acceptpip_callback}); 
        hgetbeadbtn = uicontrol('Parent', hcalibfig,'Style','pushbutton', ...
         'Units', 'normalized', 'Position', [0.3,0.1,0.2,0.1],'FontUnits','normalized',...
         'TooltipString','Define the bead for the distance calibration',...
         'String', 'Get Bead','Interruptible','on', ...
         'Callback', {@getcalibead_callback,hcalibax,handles.calibint.reference});
        hfinishbtn  = uicontrol('Parent', hcalibfig,'Style','pushbutton', ...
         'Units', 'normalized', 'Position', [0.55,0.1,0.2,0.1],'FontUnits','normalized',...
         'TooltipString','Accept calibration, return data to main function, and close this window',...
         'String', 'Finish','Interruptible','on', 'Callback', {@acceptcalib_callback});
        hcancelbtn  = uicontrol('Parent', hcalibfig,'Style','pushbutton', ...
         'Units', 'normalized', 'Position', [0.8,0.1,0.15,0.1],'FontUnits','normalized',...
         'TooltipString','Close the window, discard changes, and abort interval addition',...
         'String', '<HTML><center> Cancel <br> (reject pipette) </HTML> ',...
         'Interruptible','on', 'Callback', {@calibfigCleanup_closereq});

        set([hacceptpip,hgetbeadbtn,hfinishbtn,hcancelbtn],'Interruptible','on');
        handles.calibint.acceptedpip = false;   % add one field for this figure
     
        % read the frame
        oldframe = vidObj.CurrentFrame;
        calibframe = vidObj.readFrame(handles.calibint.reference);
        vidObj.readFrame(oldframe);   % resets the original frame number in the main figure
        imagesc(calibframe.cdata, 'Parent', hcalibax);
        colormap(gray);        
        axis(hcalibax, 'image');        % set limits of the canvas to 'image'
        hcalibax.FontUnits = 'normalized';
        
        % detect and display the pattern in this frame
        [ position, ~ ] = TrackPipette( vidObj, handles.calibint.pattern, [-1 -1],...
            [handles.calibint.frames(1) handles.calibint.frames(2)], 'wideField',true );
        handles.calibint.patcoor = [ position(2), position(1) ];
        hold(hcalibax,'on');
        rectangle('Parent', hcalibax, 'Position', ...
            [position(2), position(1), size(handles.interval.pattern,2), size(handles.interval.pattern,1)],...
            'EdgeColor','r','LineWidth', 2 );
        hold(hcalibax,'off');
        
    end

%% Accept input calibration information
    % verifies the data and closes the calibration window
    function acceptcalib_callback(~,~)
        if ~isempty(handles.calibint.beadcoor) && ~isempty(handles.calibint.contrast) && handles.calibint.acceptedpip;
            disp('All necessary data were measured, returning to the main window');
            delete(gcf);
            handles.calibint = rmfield(handles.calibint,'acceptedpip');  % remove locally used field
        else
            if ~handles.calibint.acceptedpip
                warn(strjoin({'The delineated pipette tip alignment was not verified. Please',...
                'either accept the pipette, or calcel the calibration altogether. If program is',...
                'unable to detect the pipette pattern, You need to redesign Your tracking.'}));
            else
                warn(strjoin({'Bead was not properly selected. Please make sure the appropriate bead'...
                'is chosen and appears delineated on the image.'}));
            end
            return;
        end
    end

%% Select bead for calibration
    % allows user to select the appropriate bead
    function getcalibead_callback(source,~,hax,frm)
        persistent hviscirc;
        if isgraphics(hviscirc); hviscirc.Visible = 'off'; end;     % hide the circle
        
        tag = 'interval';
        [ beadinfo, pass, rad ] = getBead( source, tag, 'hax', hax, 'frm', frm );
        source.Callback = {@getcalibead_callback,hax,frm};  % reset the callback changed in getBead method
        source.String   = 'Get Bead';
        
        if pass
            handles.calibint.beadcoor = beadinfo.coor;
            handles.calibint.contrast = beadinfo.contrast;
            hviscirc = viscircles(hax,beadinfo.coor,rad,'EdgeColor','r');
        else
            warn(strjoin({'Bead detection was unsuccessful, please try again.',...
                'Previos detection result, if any, was reverted.',...
                'If the problems continue, please try to change Your calibration frame.'}));
        end

        if isgraphics(hviscirc); hviscirc.Visible = 'on'; end;      % show the circle
    end

%% Confirm detected pipette pattern
    % confirm proper pipette pattern detection; note user cannot reposition
    % the pipette pattern in the calibration interval. If program is unable
    % to detect the pattern, it is unlikely this calibration would be of
    % any use for a completely different interval
    function acceptpip_callback(source,~)
        
        handles.calibint.acceptedpip = true;
        source.String = '<HTML><center> Reject <br> Pipette </HTML>';
        source.TooltipString = 'Recall pipette confirmation and abort the calibration';
        source.Callback = {@rejectpipette_callback};
        
    end

%% Reject detected pipette pattern
    % reject automatically detected pipette and abort the single-frame calibration
    function rejectpipette_callback(~,~)
        hw = warndlg(strjoin({'The incorrect detection of the pipette pattern in the calibration frame',...
            'means, the pattern is not transferable and another reference frame must be chosen, or',...
            'the pipette pattern tentatively expanded. The adding will abort and return to the main',...
            'window.'}),'Pipette pattern detection rejected','modal');
        uiwait(hw);
        handles.calibint = [];  % discard data
        delete(gcf);    % close calibration window
    end

%% Close calibration window
    % callback after close request of calibration figure
    function calibfigCleanup_closereq(~,~)
        
        choice = questdlg(strjoin({'You are about to cancel the calibration interval window.',...
            'If You continue, currently collected calibration data will be discarded.',...
            'The adding of an interval will be aborted and another form of calibration',...
            'will have to be set up. Are You sure You want to quit?'}),...
            'Quit outstanding calibration','Quit and abort','Continue','Continue');
        
        switch choice
            case 'Quit and abort'
                handles.calibint = [];  % clear calibration interval data
                delete(gcf);
            case 'Continue'
                return
        end
        
    end

%   =====================================================================
%%   ======== PAY NO ATTENTION TO THE MAN BEHIND THE CURTAIN ============
%   Like a wizard behind a curtain, this set of calls allows to unmess
%   minor inconveniences, mostly resulting from errors, which leave various
%   global variables switched to locked state. It can be called through
%   backdoor object, from the command line.

    function [status] = backdoorFunction( action )
        status = false;
                
        switch action
            case 'reselect'
                handles.selecting = false;
                warning(strjoin({'Selection lock removed. This function is intended only to',...
                    'help You recover after fatal error. Hope You know well, what You''re doing.'}));
                status = true;
            case 'deadwaitbar'
                set(groot,'ShowHiddenHandles','on');
                saleGosse = get(groot,'Children');
                for f=numel(saleGosse):-1:1
                    if strcmp(saleGosse(f).Tag, 'TMWWaitbar')
                        saleGosse(f).delete;
                    end
                end
                warning(strjoin({'Handles of the dead waitbars were killed. If You still see',...
                    'them, then they be undead. Good luck to You!'}));
                status = true;
        end
        
    end

end