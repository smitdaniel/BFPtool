function [ backdoorObj ] = BFPGUI( varargin )

    function [is] = isMatFile(file)
        is = false;
        if exist(file,'file')
            [~,~,ext] = fileparts(file);
            if strcmp(ext,'.mat'); is = true; end;
        end;
    end

    inp = inputParser();
    noLoad = false;
    
    addOptional(inp,'loadData', noLoad, @isMatFile)
    
    inp.parse(varargin{:});
    
    loadData = inp.Results.loadData;
    
    if loadData; 
        GUIdata = load(loadData);
        backdoorObj = GUIdata.backdoorObj;
        return;
    end
    
            
% ===================================================================


% UI settings
verbose = true;     % sets UI to provide more (true) or less (false) messages
selecting = false;  % indicates, if selection is under way and blocks other callbacks of selection
selectWrng = 'Another selection process is currently running. Finish the former and try again.';

% create backdoor object to modify hiddent parameters
backdoorObj = BFPGUIbackdoor();

% variables related to tracking
pattern = [];       % pattern to be tracked over the video
lastlistpat = [];   % the last pattern chosen for the list
patternlist = [];
bead = [];          % coordinates of bead to be tracked over the video
lastlistbead = [];  % the last bead chosen for the list
beadlist = [];
beadradius = [8,18];    % limits on radius of the bead
beadbuffer = 5;         % limit on grace period if bead cannot be detected (in frames)
pipbuffer = 5;          % limit on grace period if pipette pattern can't be detected (in frames)
beadsensitivity = 0.8;  % circle finding method sensitivity
beadgradient = 0.2;     % circle finding method gradient threshold
beadmetricthresh = 0.8; % circle finding method metric threshold
pipmetricthresh = 0.95; % pipette tracking correlation threshold
contrasthresh = 0.95;   % contrast quality threshold
overLimit = false;      % indicates if currently calculated force is within linear approx. limit of not

% variables related to video file
vidObj = [];        % video wrapper, to open videos (AVI,MP4,...) and TIFF alike
videopath = pwd;    % path to the video file
vidFrameNo = 0;     % number of the current frame
frame = [];         % the currently displayed frame
playing = true;     % video is allowed to play
disptrack = false;  % display track marks on the video
outframerate = 10;  % framerate of the output video
outsampling = 1;    % each n-th frame of original video is taken for output

% experimental parameters
pressure = 200;     % aspirating pressure of the pipette
RBCradius = 2.5;    % radius of RBC
PIPradius = 1;      % inner pipette radius
CAradius = 1.5;     % radius of contact between streptabead and RBC
P2M = 0.1024;       % pixels to microns coefficient
stiffness = 200;    % RBC stiffness

% tracking data
intfields = { 'pattern', 'patcoor', 'beadcoor', 'patsubcoor', 'contrast','reference' };
colnames = {'Range|Start', 'Range|End', 'Bead|X-coor', 'Bead|Y-coor', 'Pipette|X-coor', 'Pipette|Y-coor', 'Anchor|X-coor', 'Anchor|Y-coor', 'Remove'};
colformat = {'numeric', 'numeric','numeric', 'numeric','numeric', 'numeric','numeric', 'numeric','logical'};
tmpbeadframe = [];  % stores value of current bead frame selected for the interval
tmppatframe = [];   % ... and the same for the pipette pattern
interval = struct('frames', [0,0]);
intervallist = [];
BFPobj = [];        % BFPClass object containing the calculation/tracking
remove = [];        % list of interval entries to remove
updpatframe = 0;    % pipette pattern originating frame, updated during addition process

% plotting and fitting settings
lowplot = 1;        % lower bound of plotted data
highplot = 10;      % upper bound of plotted data
toPlot = 1;         % quantity to be plotted (1=contrast, 2=track (3D), 3=trajectories (2D), 4=force, 5=metrics)
thisPlot = [];      % quantity currently displayed in the hgraph (+6=outer graph)
thisRange = [];     % current range of frames of the plot
fitInt = [];        % interval of data to which apply the fitting procedure
kernelWidth = 5;    % width of the differentiating kernel in plateau detection
noiseThresh = sqrt(2);  % multiple of derivative's std to be considered noise (pleatea)
minLength   = 30;   % minimal number of frames to constitute plateau

% ================= SETTING UP GUI CONTROLS =========================
hfig = figure('Name', 'Pattern tracking','Units', 'normalized', 'OuterPosition', [0,0,1,1], ...
             'Visible', 'on', 'Selected', 'on');
haxes = axes('Parent',hfig,'Units', 'normalized', 'Position', [0.05,0.05,0.5,0.5],...
             'Visible', 'on');
hgraph = axes('Parent',hfig,'Units','normalized', 'Position', [0.6,0.6,0.35,0.35],...
             'ButtonDownFcn',{@getcursor_callback});
hmoviebar = uicontrol('Parent',hfig, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', 0, ...
             'Units', 'normalized', 'Enable', 'off',...
             'SliderStep', [0.01, 1], 'Position', [0.05, 0.005, 0.5, 0.015],...
             'Callback', {@videoslider_callback});
% =================================================================== 

% ================= OPENNING A VIDEO FILE ===========================
hopenvideo = uibuttongroup('Parent', hfig, 'Title','Open a video', 'Position', [0.05, 0.56, 0.25, 0.075]);
hvideopath = uicontrol('Parent',hopenvideo, 'Style', 'edit', ...
            'Units', 'normalized',...
            'String', videopath, 'Position', [0, 0.5, 1, 0.5],...
            'Enable', 'on','Callback',{@videopath_callback});
hvideobutton = uicontrol('Parent',hopenvideo,'Style','pushbutton',...
             'Units', 'normalized', 'Position', [0,0,0.2,0.5], ...
             'String', 'Open', 'Callback',{@openvideo_callback});
hvideobrowse = uicontrol('Parent',hopenvideo,'Style','pushbutton',...
             'Units', 'normalized', 'Position', [0.2,0,0.2,0.5], ...
             'String', 'Browse', 'Callback',{@browsevideo_callback});         
% ====================================================================    

% ================= WORKING WITH THE VIDEO ===========================
husevideo   = uibuttongroup('Parent', hfig, 'Title', 'Video commands', 'Units', 'normalized',...
             'Position', [0.31, 0.56, 0.24, 0.1]);
hplaybutton = uicontrol('Parent', husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0.2,0.5,0.2,0.5],...
             'String', 'Play','Interruptible','on', 'Callback', {@playvideo_callback,1});
hrewindbtn  = uicontrol('Parent', husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0,0.5,0.2,0.5],...
             'String', 'Rewind','Interruptible','on', 'Callback', {@fastvideo_callback,-5});
hffwdbutton = uicontrol('Parent', husevideo,'Style','pushbutton', ...
             'Units', 'normalized', 'Position', [0.4,0.5,0.2,0.5],...
             'String', '<HTML><center>Fast<br>forward</HTML>','Interruptible','on', 'Callback', {@fastvideo_callback,5});           
              uicontrol('Parent',husevideo, 'Style','text', 'Units', 'normalized',...
             'Position', [0.6, 0.75, 0.2, 0.25],'String','Frame: ','HorizontalAlignment','left');     
hcontrast  = uicontrol('Parent',husevideo, 'Style','pushbutton','Units', 'normalized',...
             'String', '<HTML><center>Analyse<br>contrast</HTML>', 'Position', [0,0,0.2,0.5],'Callback',{@getcontrast_callback},...
             'TooltipString', 'Calculates contrast measure curve. Useful if splitting video into intervals.');
hdispframe = uicontrol('Parent',husevideo, 'Style','pushbutton', 'Units', 'normalized',...
             'Position', [0.8, 0.75, 0.2, 0.25],'String','0/0','Callback',@gotoframe_callback,...
             'Enable','off');
hdisptrack = uicontrol('Parent', husevideo, 'Style', 'checkbox', 'Units', 'normalized',...
             'String', 'Display track info', 'Position', [0.6, 0.5, 0.4, 0.25],...
             'HorizontalAlignment','left','TooltipString','Displays tracking results on top of the video',...
             'Value', disptrack, 'Callback', {@disptrack_callback});
hgenfilm   = uicontrol('Parent', husevideo', 'Style', 'pushbutton', 'Units', 'normalized', ...
             'String',{'<HTML><center>Generate<br>film'}, 'Position', [0.2,0,0.2,0.5], 'Callback', {@generatefilm_callback},...
             'TooltipString','Generates a video file as an overlay of the open video and tracking marks');
hframeratetxt = uicontrol('Parent', husevideo, 'Style', 'text','Units','normalized',...
             'String','Framerate:','Position',[0.4,0.25,0.2,0.25],'HorizontalAlignment', 'left');
hsamplingtxt  = uicontrol('Parent', husevideo, 'Style', 'text','Units','normalized',...
             'String','Sampling:','Position',[0.4,0,0.2,0.25],'HorizontalAlignment', 'left',...
             'TooltipString','<HTML>The number signifies each n-th frame of the original video to be processed.<br>Note that processing long videos can be time demanding.</HTML>');
hfrmrate    = uicontrol('Parent',husevideo,'Style','edit','Units','normalized',...
             'String',num2str(10),'Position', [0.6,0.25,0.2,0.25],'Callback',{@outvideo_callback,10,1});
hsampling   = uicontrol('Parent',husevideo,'Style','edit','Units','normalized',...
             'String',num2str(1),'Position',[0.6,0,0.2,0.25],'Callback',{@outvideo_callback,1,2});
set([hplaybutton,hrewindbtn,hffwdbutton,hcontrast,hgenfilm],'Enable','off');         
% ====================================================================

% ================= PATTERN COLLECTION ===============================
hpatterns = uibuttongroup('Parent', hfig, 'Title', 'Pipette patterns', 'Units', 'normalized',...
            'Position', [0.56, 0.29, 0.1, 0.26],'Visible','off');
hpatternlist = uicontrol('Parent', hpatterns, 'Style', 'popup', 'String', {'no data'},...
            'Units', 'normalized', 'Position', [0,0.8,1, 0.2], 'Callback', {@pickpattern_callback});
haddpatternbtn = uicontrol('Parent', hpatterns, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0,0.5,0.5,0.15], 'String', 'Add', 'Callback', {@addpattern_callback});
hrmpatternbtn = uicontrol('Parent', hpatterns, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0.5,0.5,0.5,0.15], 'String', 'Remove', 'Callback', {@rmpattern_callback});      
hrectbutton = uicontrol('Parent',hpatterns,'Style','pushbutton',...
             'Units', 'normalized', 'Interruptible', 'off','BusyAction','cancel',...
             'Position', [0,0.65,0.5,0.15], 'String', 'Select', 'Callback',{@getrect_callback,'list'});
hpatcoortxt = uicontrol('Parent', hpatterns, 'Style', 'text' , 'String', {'[.,.;,]'},...
            'Units', 'normalized', 'Position', [0.5,0.65,0.5,0.15]);
hminiaxes = axes('Parent',hpatterns, 'Units', 'normalized', 'Position', [0.05, 0.05, 0.9, 0.44],...
             'Visible', 'on', 'XTickLabel', '', 'YTicklabel', '' );
align(hpatcoortxt,'Left','Middle');
% ====================================================================

% ================= BEAD DETECTION METHODS ===========================
hbeadmethods = uipanel('Parent', hfig, 'Title', 'Bead tracking', 'Units', 'normalized',...
            'Position', [0.56, 0.05, 0.1, 0.24],'Visible','off');
% hcontrasttgl = uicontrol('Parent',hbeadmethods, 'Style', 'togglebutton', 'Min',0, 'Max',1,...
%              'Value', 0, 'Units', 'normalized',...
%              'TooltipString', 'Dark (depressed) or bright (raised) contrast',...
%              'BackgroundColor', 'white', 'ForegroundColor', 'black', 'FontWeight', 'bold',...
%              'String', 'Bright bead', 'Position', [0,0.85,1,0.15],'Callback', {@contrasttgl_callback});  
hbeadinilist = uicontrol('Parent', hbeadmethods, 'Style', 'popup', 'String', {'no data'},...
            'Units', 'normalized', 'Position', [0,0.3,1, 0.25], 'Callback', {@pickbead_callback});
hpoitbtn = uicontrol('Parent', hbeadmethods, 'Style', 'pushbutton', 'Units', 'normalized',...
            'Position', [0,0.15,0.5,0.15], 'Interruptible', 'off','BusyAction','cancel', ...
            'String', 'Select', 'Callback', {@getpoint_callback, 'list'});
hbeadcoortxt = uicontrol('Parent', hbeadmethods, 'Style', 'text' , 'String', {'[.,.;,]'},...
            'Units', 'normalized', 'Position', [0.5,0.15,0.5,0.15]);
haddbeadbtn = uicontrol('Parent', hbeadmethods, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0,0,0.5,0.15], 'String', 'Add', 'Callback', {@addbead_callback});
hrmbeadbtn = uicontrol('Parent', hbeadmethods, 'Style', 'pushbutton', 'Units','normalized',...
            'Position', [0.5,0,0.5,0.15], 'String', 'Remove', 'Callback', {@rmbead_callback});  
% ====================================================================

% ================= PIPETTE DETECTION SETTINGS =======================
hpipdetection   = uibuttongroup('Parent', hfig, 'Title', 'Pipette detection settings', 'Units', 'normalized',...
            'Position', [0.66, 0.29, 0.1, 0.26],'Visible','off');   
hcorrthreshtxt  = uicontrol('Parent',hpipdetection, 'Style', 'text', 'String', {'Correlation'; strjoin({'thresh:', num2str(pipmetricthresh)})},...
            'TooltipString', 'Lower limit on cross correlation matching', 'Units','normalized',...
            'Position', [0,0.85,0.5,0.15]);
hcorrthresh     = uicontrol('Parent',hpipdetection,'Style','slider','Max',1,'Min',0,'Value',pipmetricthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.01,0.1],'Position',[0.5,0.85,0.5,0.15],...
             'Callback',{@pipmetric_callback});
hcontrasthreshtxt = uicontrol('Parent',hpipdetection, 'Style', 'text', 'String', {'Contrast'; strjoin({'thresh:', num2str(contrasthresh)})},...
            'TooltipString', 'Lower limit on contrast decrease', 'Units', 'normalized',...
            'Position', [0,0.7,0.5,0.15]);
hcontrasthresh  = uicontrol('Parent',hpipdetection,'Style','slider','Max',1,'Min',0,'Value',contrasthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.01,0.1],'Position',[0.5,0.7,0.5,0.15],...
             'Callback',{@pipcontrast_callback});       
hpipbufftxt     = uicontrol('Parent',hpipdetection, 'Style', 'text', 'String', 'Buffer frames',...
            'TooltipString', 'Number of consecutive frames of failed detection, allowing procedure to try to recover',...
            'Units','normalized','Position', [0,0.55,0.5,0.1]);        
hpipbuffer      = uicontrol('Parent',hpipdetection', 'Style', 'edit', 'String', num2str(pipbuffer),...
            'Units','normalized','Position',[0.5,0.55,0.5,0.15],'Callback',{@pipbuffer_callback});   
% ====================================================================

% ================= BEAD DETECTION SETTINGS ==========================
hbeaddetection = uibuttongroup('Parent', hfig, 'Title', 'Bead detection settings', 'Units', 'normalized',...
            'Position', [0.66, 0.05, 0.1, 0.24],'Visible','off');
              uicontrol('Parent', hbeaddetection, 'Style', 'text', 'String', 'Radius range',...
            'Units', 'normalized','Position', [0,0.85,0.5,0.1]);
hminrad     = uicontrol('Parent', hbeaddetection, 'Style', 'edit', 'String', num2str(beadradius(1)),...
            'Units', 'normalized','Position', [0.5,0.85,0.2,0.15],'Callback', {@setrad_callback});
hmaxrad     = uicontrol('Parent', hbeaddetection, 'Style', 'edit', 'String', num2str(beadradius(2)),...
            'Units', 'normalized','Position', [0.75,0.85,0.2,0.15],'Callback', {@setrad_callback});
                uicontrol('Parent', hbeaddetection, 'Style', 'text', 'String', 'Buffer frames',...
                    'TooltipString', 'Number of frames allowed to pass without successful bead detection',...
                    'Units', 'normalized','Position', [0,0.7,0.5,0.1]);
hbuffer = uicontrol('Parent', hbeaddetection, 'Style', 'edit', 'String', num2str(beadbuffer),...
            'Units', 'normalized','Position', [0.5,0.7,0.2,0.15],'Callback', {@setbuffer_callback});
hsensitivitytxt = uicontrol('Parent', hbeaddetection, 'Style', 'text', 'String', {'Sensitivity: ';num2str(round(beadsensitivity,2))},...
                    'TooltipString', 'Higher sensitivity detects more circular objects, including weak and obscured',...
                    'Units', 'normalized','Position', [0,0.55,0.5,0.15]);
hsensitivitybar = uicontrol('Parent',hbeaddetection, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', beadsensitivity, ...
             'Units', 'normalized', 'Enable', 'on',...
             'SliderStep', [0.01, 0.1], 'Position', [0.5, 0.55, 0.5, 0.15],...
             'Callback', {@beadsensitivity_callback});
hgradbar = uicontrol('Parent',hbeaddetection, 'Style', 'slider', 'Max', 1, 'Min', 0, 'Value', beadgradient, ...
             'Units', 'normalized', 'Enable', 'on',...
             'SliderStep', [0.01, 0.1], 'Position', [0.5, 0.4, 0.5, 0.15],...
             'Callback', {@beadgrad_callback});
hgradtxt = uicontrol('Parent', hbeaddetection, 'Style', 'text', 'String', {'Gradient: ';num2str(round(beadgradient,2))},...
             'TooltipString', 'Lower gradient threshold detects more circular objects, including weak and obscured',...
             'Units', 'normalized','Position', [0,0.4,0.5,0.15]);
hmetrictxt  = uicontrol('Parent',hbeaddetection,'Style','text','String',{'Metric';strjoin({'thresh:',num2str(beadmetricthresh)})},...
             'TooltipString', 'Lower threshold gives more credibility to less certain findings',...
             'Units','normalized','Position',[0,0.25,0.5,0.15]);
hmetric     = uicontrol('Parent',hbeaddetection,'Style','slider','Max',2,'Min',0,'Value',beadmetricthresh,...
             'Units','normalized','Enable','on','SliderStep',[0.005,0.1],'Position',[0.5,0.25,0.5,0.15],...
             'Callback',{@beadmetric_callback});
% ====================================================================

% ==================== SELECTING INTERVALS TO TRACK ==================
hintervals  = uitabgroup('Parent', hfig, 'Units','normalized', 'Position', [0.05, 0.635, 0.25, 0.125]);
hsetinterval  = uitab('Parent', hintervals, 'Title', 'Set interval', 'Units', 'normalized');
            uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', 'Interval:', ...
                      'TooltipString', 'Interval of interest for tracking, in frames',...
                      'Units','normalized','Position', [0,0.75,0.25,0.25],'HorizontalAlignment','left' );
hstartint   = uicontrol('Parent', hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.25,0.75,0.15,0.25],'Callback',{@setintrange_callback,0,1});
hshowframe  = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'Show', ...
                      'Units','normalized','Position', [0.4,0.75,0.1,0.25],'Enable','off',...
                      'Callback',{@gotointframe_callback});                  
hendint     = uicontrol('Parent', hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.5,0.75,0.25,0.25],'Callback',{@setintrange_callback,0,2});
hrefframe  = uicontrol('Parent',hsetinterval, 'Style', 'edit', 'String', [],'Enable','off',...
                      'Units','normalized','Position', [0.75,0.75,0.15,0.25],...
                      'Callback',{@setrefframe_callback,0});
hgetrefframe = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', {'Get';'current'}, ...
                      'Units','normalized','Position', [0.9,0.75,0.1,0.25],'Enable','off',...
                      'TooltipString', 'Sets currently visible frame as the reference frame',...
                      'Callback', {@getrefframe_callback});                  
               uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', 'Selected pattern:', ...
                      'TooltipString', 'Pattern to be tracked over the interval',...
                      'Units','normalized','Position', [0,0.5,0.25,0.25],'HorizontalAlignment','left' );
hpatternint  = uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', '[.,.;.]', ...
                      'TooltipString', 'Coordinates of the selected pattern',...
                      'Units','normalized','Position', [0.25,0.5,0.25,0.25],'HorizontalAlignment','center' );                  
hshowpattern = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'Show', ...
                      'Units','normalized','Position', [0.75,0.5,0.25,0.25],'Enable','off',...
                      'Callback',{@showintpattern_callback});
hgetpattern  = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'List', ...
                      'Units','normalized','Position', [0.5,0.5,0.125,0.25],...
                      'Enable','off','Callback',{@getintpat_callback});
hselectpat   = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'Select', ...
                      'Units','normalized','Position', [0.625,0.5,0.125,0.25],...
                      'Enable','off','Callback',{@getrect_callback,'interval'});                  
               uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', 'Selected bead:', ...
                      'TooltipString', 'Bead to be tracked over the interval',...
                      'Units','normalized','Position', [0,0.25,0.25,0.25],'HorizontalAlignment','left' );                  
hbeadint     = uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', '[.,.;.]', ...
                      'TooltipString', 'Coordinates of the selected bead',...
                      'Units','normalized','Position', [0.25,0.25,0.25,0.25],'HorizontalAlignment','center' );                  
hgetbead     = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'List', ...
                      'Units','normalized','Position', [0.5,0.25,0.125,0.25],...
                      'Enable','off','Callback',{@getintbead_callback});
hselectbead  = uicontrol('Parent',hsetinterval, 'Style', 'pushbutton', 'String', 'Select', ...
                      'Units','normalized','Position', [0.625,0.25,0.125,0.25],...
                      'Enable','off','Callback',{@getpoint_callback,'interval'});                  
               uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', 'Pattern anchor:', ...
                      'TooltipString', 'Precise point on the pattern, whose position in time should be reported',...
                      'Units','normalized','Position', [0,0,0.25,0.25],'HorizontalAlignment','left' );
hpatsubcoor  = uicontrol('Parent',hsetinterval, 'Style', 'text', 'String', '[.,.]', ...
                      'TooltipString', 'Precise point on the pattern to be tracked',...
                      'Units','normalized','Position', [0.25,0,0.25,0.25],'HorizontalAlignment','center');
hgetpatsubcoor = uicontrol('Parent',hsetinterval, 'Style','pushbutton', 'String', 'Select',...
                      'Units','normalized','Position', [0.5,0,0.25,0.25], 'Enable','off',...
                      'Callback', {@getpatsubcoor_callback});
haddinterval = uicontrol('Parent',hsetinterval, 'Style','pushbutton','String',{'Add to list'},...
                      'Units','normalized','Position', [0.75,0,0.25,0.5],...
                      'Enable','off','Callback',{@addinterval_callback});
% ====================================================================

% ============== TABLE OF INTERVALS ==================================
hlistinterval = uitab('Parent', hintervals, 'Title', 'List of intervals', 'Units', 'normalized');
heraseint     = uicontrol('Parent',hlistinterval,'Style','pushbutton', 'String', 'Erase', 'Units',...
                'normalized', 'Position', [0.9,0.5,0.1,0.5], 'Enable', 'off',...
                'Callback',{@eraseint_callback});
% ====================================================================

% ============== EXPERIMENTAL PARAMETERS =============================
hexpdata = uibuttongroup('Parent', hfig, 'Title','Experimental parameters', 'Units','normalized',...
            'Position', [0.05, 0.76, 0.25, 0.1],'Visible','off');
hprestxt    = uicontrol('Parent', hexpdata, 'Style', 'text', 'String', 'Pressure:',...
            'Units', 'normalized','Position', [0,0.75,0.25,0.25]);
hpressure   = uicontrol('Parent', hexpdata, 'Style', 'edit', 'String', num2str(pressure),...
            'Units', 'normalized','Position', [0.25,0.75,0.2,0.25],'Callback', {@setexpdata_callback,pressure}); 
hRBCtxt     = uicontrol('Parent', hexpdata, 'Style', 'pushbutton', 'String','RBC radius:',...
            'Units', 'normalized','Position', [0,0.5,0.25,0.25],'Callback',@measureRBC_callback);
hRBCrad     = uicontrol('Parent', hexpdata, 'Style', 'edit', 'String', num2str(RBCradius),...
            'Units', 'normalized','Position', [0.25,0.5,0.2,0.25],'Callback', {@setexpdata_callback,RBCradius});
hPIPtxt     = uicontrol('Parent', hexpdata, 'Style', 'pushbutton', 'String', 'Pipette radius:',...
            'Units', 'normalized','Position', [0,0.25,0.25,0.25],'Callback',{@measureLength_callback,'pipette'});
hPIPrad     = uicontrol('Parent', hexpdata, 'Style', 'edit', 'String', num2str(PIPradius),...
            'Units', 'normalized','Position', [0.25,0.25,0.2,0.25],'Callback', {@setexpdata_callback,PIPradius}); 
hCAtxt      = uicontrol('Parent', hexpdata, 'Style', 'pushbutton', 'String', 'Contact radius:',...
            'Units', 'normalized','Position', [0,0,0.25,0.25],'Callback',{@measureLength_callback,'contact'});
hCArad      = uicontrol('Parent', hexpdata, 'Style', 'edit', 'String', num2str(CAradius),...
            'Units', 'normalized','Position', [0.25,0,0.2,0.25],'Callback', {@setexpdata_callback,CAradius});
hP2Mtxt     = uicontrol('Parent', hexpdata, 'Style', 'text', 'String', 'Pixel to micron:',...
            'Units', 'normalized','Position', [0.5,0.75,0.25,0.25]);
hP2M        = uicontrol('Parent', hexpdata, 'Style', 'edit', 'String', num2str(P2M),...
            'Units', 'normalized','Position', [0.75,0.75,0.2,0.25],'Callback', {@setexpdata_callback,P2M});
set([hprestxt,hRBCtxt,hPIPtxt,hCAtxt,hP2Mtxt],'HorizontalAlignment','left');
% ====================================================================

% ================= VIDEO INFORMATION ================================
hvidinfo = uipanel('Parent', hfig,'Title','Video information', 'Units','normalized',...
            'Position', [0.05, 0.86, 0.25, 0.1]);
hvidheight = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Height:', 'Position', [0,0.75,0.5,0.25]);
hvidwidth = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Width:', 'Position', [0,0.5,0.5,0.25]);
hvidduration = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Duration:', 'Position', [0,0.25,0.5,0.25]);
hvidframes = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Frames:', 'Position', [0,0,0.5,0.25]);
hvidframerate = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Framerate:', 'Position', [0.5,0,0.5,0.25]);
hvidname = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Name:', 'Position', [0.5,0.25,0.5,0.25]);
hvidformat = uicontrol('Parent', hvidinfo, 'Style', 'text', 'Units', 'normalized',...
            'HorizontalAlignment','left','String', 'Format:', 'Position', [0.5,0.5,0.5,0.25]);        
% ====================================================================

% ================= RUNNING CALCULATION ==============================
hcalc =     uipanel('Parent', hfig, 'Title', 'Tracking', 'Units', 'normalized',...
                'Position', [0.76,0.05,0.1,0.5]);
hupdate      =   uicontrol('Parent', hcalc, 'Style','pushbutton','String', 'Update', 'Units', 'normalized',...
                'Position', [0, 0.85, 0.5, 0.15], 'Enable', 'off', 'Callback', {@update_callback});
hruntrack    =   uicontrol('Parent', hcalc, 'Style', 'pushbutton', 'String', 'Track', 'Units', 'normalized',...
                'Position', [0.5, 0.85,0.5,0.15], 'Enable', 'off','Callback', {@runtrack_callback});
hrunforce    =   uicontrol('Parent', hcalc, 'Style', 'pushbutton', 'String', '<HTML><center>Get<br>Force</HTML>', 'Units', 'normalized',...
                'Position', [0.5, 0.7,0.5,0.15], 'Enable', 'off','Callback', {@runforce_callback});            
hgraphplot   =   uicontrol('Parent', hcalc, 'Style', 'pushbutton', 'String', 'Plot', 'Units', 'normalized',...
                'Position', [0,0.5, 0.5, 0.15], 'Enable', 'off', 'Callback', {@graphplot_callback});
hgraphitem   =   uicontrol('Parent', hcalc, 'Style', 'popup', 'String', {'Contrast', 'Tracks (3D)', 'Trajectories (2D)', 'Force', 'Metrics'},...
                'Units','normalized','Position', [0,0.35,0.5,0.15], 'Enable', 'off',...
                'Callback', {@graphpopup_callback});
hgraphbead   =   uicontrol('Parent', hcalc, 'Style', 'checkbox', 'String', 'Bead', 'Enable', 'off',...
                'Units','normalized','Position', [0.5, 0.35, 0.5, 0.075]);
hgraphpip    =   uicontrol('Parent',hcalc, 'Style', 'checkbox', 'String', 'Pipette', 'Enable', 'off',...
                'Units','normalized','Position', [0.5, 0.425, 0.5, 0.075]);
hlowplot     =   uicontrol('Parent', hcalc,'Style','edit','String', num2str(lowplot), 'Units','normalized',...
                'Position', [0.5,0.5,0.25,0.15], 'Enable','off','Callback', {@plotrange_callback,lowplot,1});
hhighplot    =   uicontrol('Parent', hcalc,'Style','edit','String', num2str(highplot), 'Units','normalized',...
                'Position', [0.75,0.5,0.25,0.15],'Enable','off', 'Callback', {@plotrange_callback,highplot,2});
hreport      =   uicontrol('Parent', hcalc,'Style','pushbutton', 'String', '<HTML><center>View<br>Report</HTML>',...
                'Tooltipstring', 'Displays summary of the last tracking, illustrating intervals with poor trackability',...
                'Units','normalized','Position',[0,0.25,0.5,0.1],'Enable','off','Callback', {@getreport_callback});
hlinearinfo  =   uicontrol('Parent', hcalc,'Style','pushbutton','String','<HTML><center><font size="3" color="black">?</font></HTML>',...
                'Units','normalized','Position',[0,0.65,0.25,0.05],'Enable','off','Callback',{@lininfo_callback},...
                'TooltipString','Information on reliability of linear approximation of force');
% ====================================================================

% ========================= BASIC FITTING ============================
hfit        = uipanel('Parent',hfig,'Title','Basic Fitting', 'Units','normalized',...
                'Position', [0.45,0.66,0.1,0.30]);
hfitline    = uicontrol('Parent',hfit,'Style','pushbutton','String','<HTML><center>Fit<br>line</HTML>',...
                'Units','normalized','Position',[0,0.85,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'line',false});
hfitexp     = uicontrol('Parent',hfit,'Style','pushbutton','String','<HTML><center>Fit<br>exponentiel</HTML>',...
                'Units','normalized','Position',[0,0.7,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'exp',false});
hfitplateau = uicontrol('Parent',hfit,'Style','pushbutton','String','<HTML><center>Fit<br>plateau</HTML>',...
                'Units','normalized','Position',[0,0.55,1,0.15],'Enable','off',...
                'Callback',{@fit_callback,'plat',false});
hgetplatwidth = uicontrol('Parent',hfit,'Style','edit','String', num2str(kernelWidth),...
                'TooltipString', strcat('<HTML>Defines the sensitivity of differentiating kernel.<br>',...
                'The kernel is derivative of Gaussian. Sensitivity is then std of the original Gaussian.</HTML>'),...
                'Units','normalized','Position',[0,0.4,0.4,0.15],'Callback',{@getplat_callback,1},...
                'Visible','off');
hplatwidth    = uicontrol('Parent',hfit,'Style','pushbutton','String',strcat('<HTML><center>Sensitivity<br>',...
                num2str(round(kernelWidth)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines the sensitivity of differentiating kernel.<br>',...
                'The kernel is derivative of Gaussian. Sensitivity is then &sigma of the original Gaussian.</HTML>'),...
                'Units','normalized','Position',[0,0.4,0.4,0.15],'Callback',{@platswitch_callback,hgetplatwidth},...
                'Enable','off');
hgetplatthresh= uicontrol('Parent',hfit,'Style','edit','String', num2str(noiseThresh),...
                'TooltipString', strcat('<HTML>Defines the threshold of noise.<br>',...
                'Multiple of std of force derivative to be still considered noise.</HTML>'),...
                'Units','normalized','Position',[0.4,0.4,0.3,0.15],'Callback',{@getplat_callback,2},...
                'Visible','off');                        
hplatthresh   = uicontrol('Parent',hfit,'Style','pushbutton','String',strcat('<HTML><center>Thresh<br>',...
                num2str(round(noiseThresh,1)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines the threshold of noise.<br>',...
                'Multiple of std of force derivative to be still considered noise.</HTML>'),...
                'Units','normalized','Position',[0.4,0.4,0.3,0.15],'Callback',{@platswitch_callback,hgetplatthresh},...
                'Enable','off');            
hgetplatmin   = uicontrol('Parent',hfit,'Style','edit','String', num2str(minLength),...
                'TooltipString', strcat('<HTML>Defines minimal length of plateau.<br>',...
                'Minimal number of continuous frames with derivative below threshold, to constitute a plateau.</HTML>'),...
                'Units','normalized','Position',[0.7,0.4,0.3,0.15],'Callback',{@getplat_callback,3},...
                'Visible','off');                        
hplatmin      = uicontrol('Parent',hfit,'Style','pushbutton','String',strcat('<HTML><center>Length<br>',...
                num2str(round(minLength)),'</HTML>'), 'TooltipString', strcat('<HTML>Defines minimal length of plateau.<br>',...
                'Minimal number of continuous frames with derivative below threshold, to constitute a plateau.</HTML>'),...
                'Units','normalized','Position',[0.7,0.4,0.3,0.15],'Callback',{@platswitch_callback,hgetplatmin},...
                'Enable','off');   
hfitint       = uicontrol('Parent',hfit,'Style','pushbutton','String','<HTML><center>Choose<br>interval</HTML>',...
                'Units','normalized','Position',[0,0,1,0.15],'Callback',{@fitint_callback});            
% ====================================================================            

% ================= IMPORT,EXPORT,UI SETTINGS ============================
hio      = uipanel('Parent',hfig,'Title','Import, export, UI settings', 'Units','normalized',...
            'Position', [0.33,0.66,0.12,0.30]);
hvar     = uicontrol('Parent', hio, 'Style', 'popupmenu', 'Units', 'normalized', 'String',...
            {'force & tracks'; 'frame'; 'graph'; 'parameters'}, 'Enable', 'on', 'Position',...
            [0,0.9,1,0.1], 'Callback', {@port_callback});
htar     = uicontrol('Parent', hio, 'Style', 'popupmenu', 'Units', 'normalized', 'String',...
            {'workspace'; 'data file'; 'figure/media'}, 'Enable', 'on', 'Position',...
            [0,0.6,1,0.1], 'Callback', {@port_callback});
hexport  = uicontrol('Parent', hio, 'Style','pushbutton','Units','normalized','String',...
            strcat('Export',char(8595)),...
            'Position', [0,0.75,0.5,0.15],'Callback',{@export_callback}, 'Enable','on');
himport  = uicontrol('Parent', hio, 'Style','pushbutton','Units','normalized','String',...
            strcat('Import',char(8593)),...
            'Position', [0.5,0.75,0.5,0.15],'Callback',{@import_callback}, 'Enable','off');
hverbose = uicontrol('Parent', hio, 'Style','checkbox','Units','normalized','String','Verbose output',...
            'Min', 0, 'Max', 1, 'Value',1 ,'Position', [0,0.4,1,0.15],'Callback',{@verbose_callback},...
            'TooltipString','Verbose output means more warnings, suggestions, dialog windows etc.');
hhideexp = uicontrol('Parent',hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.25,1,0.1],'String','Show experimental data panel','Callback',{@hidepanel_callback,'experimental data',hexpdata});
hhidelist= uicontrol('Parent',hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.15,1,0.1],'String','Show tracking list panel','Callback',{@hidepanel_callback,'tracking list',[hpatterns,hbeadmethods]});
hhidedet = uicontrol('Parent',hio,'Style','togglebutton','Min',0, 'Max',1,'Value',0,'Units','normalized',...
            'Position',[0,0.05,1,0.1],'String','Show advanced detection panel','Callback',{@hidepanel_callback,'advanced detection',[hpipdetection,hbeaddetection]});
%hBDtest = uicontrol('Parent', hio, 'Style', 'pushbutton','Units','normalized','Position', [0,0.25,1,0.15],...
%            'String', 'Disclose', 'TooltipString', 'Pay no attention to that man behind the curtain',...
%            'Callback', {@BDtest_callback});

            
% ================= CALLBACK FUNCTIONS ===============================

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

    % allows various import possibilities
    function import_callback(~,~)
        var = hvar.Value;       % which variable is to be imported; 1=force & track, 2=frame, 3=graph, 4=parameters
        src = htar.Value;       % target of the import; 1=workspace, 2=datafile, 3=figure
        
        if isempty(BFPobj)          % BFPobj was not yet instantiated
            BFPobj = BFPClass();    % call default constructor
        end;
        
        dlgstr = [];
        
        % nested function; prepares import for various input types
        function importFeed(dataString)
            fileName = getFileName(strcat(dataString,'.dat'));
            inData = dlmread(fileName);
            BFPobj.importData(dataString,inData)
            set([hgraphitem, hgraphplot, hlowplot, hhighplot], 'Enable', 'on');
        end
                         
        switch var
            case 1  % force & tracks
                if src==1       % workspace - no action
                elseif src==2   % datafiles
                    if verbose
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
                            hgraphpip.Enable = 'on';
                        case 'Bead track'     
                            importFeed('beadPositions');
                            hgraphbead.Enable = 'on';
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
                    cla(hgraph);                                                        % clear the axes
                    himportgraph = copyobj(allchild(himportaxes), hgraph);              % copy axes into hgraph axes
                    set(himportgraph, 'HitTest','off');
                    thisPlot = 6;       % flag saying fitting is possible, but data is outer
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
                    cla(hgraph);
                    himportgraph = copyobj(allchild(himportaxes), hgraph);      % copy axes into hgraph axes
                    set(himportgraph, 'HitTest','off');
                    thisPlot = 6;
                    delete(importfig);
                end
                
            case 4  % parameters
                if src==1       % workspace - no action
                elseif src==2   % datafile (here .mat file)
                    fileName = getFileName('BFPparameters.mat');
                    origin = ancestor(hfig,'figure');   % find the ancestor of the GUI
                    delete(origin);  
                    GUIdata = load(fileName);
                    backdoorObj = GUIdata.backdoorObj;
                    assignin('base','BFPbackdoor',backdoorObj); % send the new backdoor to the base WS
                elseif src==3   % figure/image - no action
                end                  
            
        end
    end

    % allows various combinations of figure elements and targets of export
    function export_callback(~,~)
        var = hvar.Value;       % which variable is to be exported; 1=force & track, 2=frame, 3=graph, 4=parameters
        tar = htar.Value;       % target of the export; 1=workspace, 2=datafile, 3=figure
        
        switch var
            case 1  % force & tracks
                if tar==1       % workspace
                    assignin('base','force',BFPobj.force);
                    assignin('base','pipPositions',BFPobj.pipPositions);
                    assignin('base','beadPositions',BFPobj.beadPositions);
                elseif tar==2   % datafiles
                    fileName = putFileName('force.dat');
                    force = zeros(BFPobj.trackedFrames,2);  % prealocate
                    i=1;
                    for frm=BFPobj.minFrame:BFPobj.maxFrame
                        force(i,:) = [frm, BFPobj.getByFrame(frm,'force')];
                        i=i+1;
                    end
                    dlmwrite(fileName, force);
                    fileName = putFileName('pipPositions.dat');
                    pipPos = zeros(BFPobj.trackedFrames,3);
                    i=1;
                    for frm=BFPobj.minFrame:BFPobj.maxFrame
                        pipPos(i,:) = [frm, BFPobj.getByFrame(frm,'pipette')];
                        i=i+1;
                    end
                    dlmwrite(fileName, pipPos);
                    fileName = putFileName('beadPositions.dat');
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
                    capture = getframe(haxes);
                    assignin('base','capturedFrame', capture);
                elseif tar==2;  % datafile - no action
                elseif tar==3   % figure/media
                    htempfig = figure('Name','transient','Visible','on');
                    hnewaxes = copyobj(haxes,htempfig);
                    set(hnewaxes, 'Units','normalized','OuterPosition',[0,0,1,1]);  % save access, fill the whole figure
                    colormap(hnewaxes,gray);            % makes sure colormap is gray
                    fileName = putFileName('frame.bmp');% call to set up filepath
                    saveas(htempfig,fileName);          % save the trans. figure
                    delete(htempfig);
                end
                
            case 3 % graph
                if tar==1       % workspace
                    hexportfig = figure('Name','BFP - graph');
                    hexportgraph = copyobj(hgraph, hexportfig);
                    set(hexportgraph, 'Units', 'normalized', 'OuterPosition', [0,0,1,1]);
                    set(allchild(hexportgraph),'HitTest','on');
                    assignin('base','BFPgraph',hexportfig);
                elseif tar==2   % datafile
                    if isempty(thisPlot); 
                        if verbose; helpdlg('Nothing to plot. Try to replot.','Empty graph');end;
                        return;
                    else
                        lines = findobj(hgraph,'type','line');  % get lines in the graph
                        graphData = []; % declare
                        switch thisPlot
                            case 1          % contrast
                                graphData.name = putFileName('contrastGraph.dat');
                                graphData.coor(:,1) = lines.XData;
                                graphData.coor(:,2) = lines.YData;                                
                            case { 2, 3 }   % trajectories
                                for child = 1:numel(lines)
                                    
                                    if ~isempty(lines(child).ZData)
                                        graphData(child).coor(:,1) = get(lines(child),'ZData');
                                    else
                                        graphData(child).coor(:,1) = thisRange(1):thisRange(2);
                                    end;
                                    graphData(child).coor(:,2) = get(lines(child),'XData');
                                    graphData(child).coor(:,3) = get(lines(child),'YData');
                                    
                                    if graphData(child).coor(1,2:3) == BFPobj.getByFrame(thisRange(1),'bead');
                                        graphData(child).name = putFileName('beadGraph.dat');
                                    elseif graphData(child).coor(1,2:3) == BFPobj.getByFrame(thisRange(1),'pipette');
                                        graphData(child).name = putFileName('pipGraph.dat');
                                    end
                                    
                                end
                            case 4  % force
                                graphData.name = putFileName('forceGraph.dat');
                                graphData.coor(:,1) = lines.XData;
                                graphData.coor(:,2) = lines.YData;
                        end
                        for child = 1:numel(lines)
                            dlmwrite(graphData(child).name, graphData(child).coor);
                        end
                    end
                elseif tar==3   % figure/image
                    htempfig = figure('Name','transient','Visible','on');
                    hnewaxes = copyobj(hgraph,htempfig);
                    set(hnewaxes, 'Units','normalized','OuterPosition',[0,0,1,1]);  % save access, fill the whole figure
                    fileName = putFileName('BFPgraph.fig'); % call to set up filepath
                    saveas(htempfig,fileName);              % save the trans. figure
                    delete(htempfig);
                end
                
            case 4  % parameters
                if tar==1       % workspace - no action
                elseif tar==2   % datafile (here .mat file)
                    fileName = putFileName('BFPparameters.mat');
                    save(fileName);
                elseif tar==3   % figure/image - no action
                end                  
            
        end
    end
    
    % choosing various combinations has various effects
    function port_callback(~,~)
        var = hvar.Value;
        tar = htar.Value;
        
        switch var  % variable switch
            case 1  % force & tracks
                switch tar
                    case 1  % workspace
                        hexport.Enable = 'on';
                        himport.Enable = 'off'; %!!!
                    case 2  % datafile
                        hexport.Enable = 'on';
                        himport.Enable = 'on';
                    case 3  % figure; no IO for data <-> figure
                        hexport.Enable = 'off';
                        himport.Enable = 'off';
                        if verbose; 
                            helpdlg(strjoin({'Export of data into figure and visa versa is not possible.',...
                                'If You wish to use data to produce figure, You can export them to the Matlab basic workspace.'}),...
                                'Unsupported export/import');
                        end;
                end
            case 2  % frame
                switch tar
                    case 1  % workspace
                        hexport.Enable = 'on';
                        himport.Enable = 'off';
                    case 2  % datafile
                        hexport.Enable = 'off'; % no frame export to data
                        himport.Enable = 'off';
                        if verbose;
                            helpdlg(strjoin({'Export of frame into datafile (i.e. not image or figure) is not possible',...
                                'If You wish to export current frame into external file, use media or figure file.'}),...
                                'Unsupported export/import');
                        end
                    case 3  % figure/media
                        hexport.Enable = 'on';
                        himport.Enable = 'off';
                end
            case 3 % graph
                switch tar
                    case 1  % workspace
                        hexport.Enable = 'on';
                        himport.Enable = 'on';
                    case 2  % datafile
                        hexport.Enable = 'on';  % exports underlying data into datafile
                        himport.Enable = 'off'; % no import of data into graph, they can plot them elsewhere
                    case 3  % figure/media
                        hexport.Enable = 'on';
                        himport.Enable = 'on';  % figure only
                end
            case 4  % parameters
                switch tar
                    case 1  % workspace
                        hexport.Enable = 'off';
                        himport.Enable = 'off';
                        if verbose;
                            helpdlg('Export and import of parameters between workspaces is currently not possible.',...
                                    'Unsupported import/export');
                        end
                    case 2  % datafile
                        hexport.Enable = 'on';
                        himport.Enable = 'on';
                    case 3
                        hexport.Enable = 'off';
                        himport.Enable = 'off';
                        if verbose; 
                            helpdlg('Export of parameters into figure and visa versa is not possible.', 'Unsupported export/import');
                        end;
                end
        end        
    end
       
    % sets the 'verbose' flag
    function verbose_callback(source,~)
        verbose = logical(source.Value);
    end

    % changes UI to allow user input
    function platswitch_callback(source,~,setter)
        source.Visible = 'off';
        setter.Visible = 'on';
    end

    % reads and sets the value
    function getplat_callback(source,~,var)
        val = str2double(source.String);
        if ( isnan(val) || val < 0 )
            warndlg('The input must be a positive number.','Incorrect input','replace');
            switch var
                case 1
                    source.String = num2str(kernelWidth);
                case 2
                    source.String = num2str(noiseThresh);
                case 3
                    source.String = num2str(minLength);
            end
            return;
        end
        source.Visible = 'off';
        switch var
            case 1
                kernelWidth = val;
                hplatwidth.String = strcat('<HTML><center>Sensitivity<br>',...
                num2str(round(kernelWidth)),'</HTML>');
                hplatwidth.Visible = 'on';
            case 2
                noiseThresh = val;
                hplatthresh.String = strcat('<HTML><center>Thresh<br>',...
                num2str(round(noiseThresh,1)),'</HTML>');
                hplatthresh.Visible = 'on';
            case 3
                minLength = val;
                hplatmin.String = strcat('<HTML><center>Length<br>',...
                num2str(round(minLength)),'</HTML>');
                hplatmin.Visible = 'on';
        end
    end
    
    % fitting the graph; only one type of fitting line at the time
    function fit_callback(~,~,type,limit)
        
        getcursor_callback(0,0,true);   % delete possible point marker
        
        % fitted lines are persistent; erased every time fitting is called
        persistent hfitplot;
        persistent hsublimplot;
        if numel(hfitplot); 
            for p=1:numel(hfitplot); 
                hfitplot(p).ph.delete;
                hfitplot(p).txt.delete;
            end;
        end
        if numel(hsublimplot); 
            for p=1:numel(hsublimplot); 
                hsublimplot(p).ph.delete;
                hsublimplot(p).txt.delete;
            end;
        end
        
        if thisPlot ~= 4 && thisPlot ~= 1 && thisPlot ~=5 && thisPlot ~= 6
            choice = questdlg(['The fitting procedure is available only for force, contrast, metrics and imported outer graph',...
                    'Would You like to switch graph?'],'Force fitting','Force','Contrast','Metrics', 'Cancel','Force');
            switch choice
                case 'Force'
                    toPlot = 4;
                    hgraphitem.Value = toPlot;
                    graphplot_callback(0,0);
                case 'Contrast'
                    toPlot = 1;
                    hgraphitem.Value = toPlot;
                    graphplot_callback(0,0);
                case 'Metrics'
                    toPlot = 5;
                    hgraphitem.Value = toPlot;
                    graphplot_callback(0,0);
                case 'Cancel'
                    return;
            end
        end
        
        % set up descriptive strings
        switch thisPlot
            case 4    % force
                units = 'pN$$';
                quant = '$$\bar{F}=';
                rnd = 1;
            case 1  % contrast
                units = '$$';
                quant = '$$\bar{C}=';
                rnd = 3;
            case 5  % metrics
                units = '$$';
                quant = '$$\bar{\mu}=';
                rnd = 3;
        end
        
        % set fitting interval
        if isempty(fitInt); fitInt = [ hgraph.XLim(1), 0; hgraph.XLim(2), 0] ; end;     % if none provided, select current graph limits
        hfitint.String = strcat('<HTML><center>Change<br>[',num2str(round(fitInt(1,1))),',',...
                         num2str(round(fitInt(2,1))),']</HTML>');                       % save the info about the current fitting interval
        
        int = (fitInt(1,1):fitInt(2,1))';   % set the selected interval
        frc = zeros(numel(int),1);          % preallocate data to be fit
        
        hplotline = findobj(hgraph,'Type','line');  % find the data line
        for l = 1:numel(hplotline)
            xmin = hplotline(l).XData(1);
            frc(:,l) = hplotline(l).YData(int-xmin+1)';
        end;
            
        nextPlateau = 1;
        
        hold(hgraph,'on');
        
        for l=1:size(frc,2) % for all fitted data columns
            switch type
                case 'line'
                    [ coeff, err ] = polyfit( int, frc(:,l), 1);
                    [ ffrc, ~ ] = polyval( coeff, int, err );
                    disp(strcat('Fitted slope: ',num2str(coeff(1))) );
                    hfitplot(l).ph = plot(hgraph, int, ffrc, 'r', 'HitTest', 'off');
                    str = strcat('$$r=',num2str(coeff(1)),'$$');
                    pos = 0.5*[ (int(end) + int(1)), (ffrc(end)+ffrc(1)) ];
                    hfitplot(l).txt = text( 'Parent', hgraph, 'interpreter', 'latex', 'String', str, ...
                'Units', 'data', 'Position', pos, 'Margin', 1, ...
                'LineStyle','none', 'HitTest','off','FontSize',14, 'FontWeight','bold','Color','red',...
                'VerticalAlignment','top');
                case 'exp'
                    if ~isempty(vidObj)     % make sure vidObj exist, if it doesn't, outer data are being fit
                        if (vidObj.Framerate ~= 0)
                            [ coeff, ffrc ] = expfit( int, frc(:,l), 'framerate', vidObj.Framerate );
                        end
                    else    % case for imported data
                        [ coeff, ffrc ] = expfit( int, frc(:,l) );
                    end
                    disp(strcat('Time constant: ',num2str(coeff(1))) );
                    str = strcat('$$\eta=',num2str(coeff(1)),'$$');
                    pos = 0.5*[ (int(end) + int(1)), (ffrc(end)+ffrc(1)) ];
                    hfitplot(l).txt = text( 'Parent', hgraph, 'interpreter', 'latex', 'String', str, ...
                'Units', 'data', 'Position', pos, 'Margin', 1, ...
                'LineStyle','none', 'HitTest','off','FontSize',14, 'FontWeight','bold','Color','red',...
                'VerticalAlignment','middle');
                    hfitplot(l).ph = plot(hgraph, int, ffrc, 'r', 'HitTest', 'off');
                case 'plat'
                    sf = backdoorObj.edgeDetectionKernelSemiframes;         % default 10
                    if numel(int) < (2*sf + 5)      % require at least 4 points with analysis
                        warndlg('Interval is too short for analysis','Insufficient data', 'replace');
                        return;
                    end
                    locint = int(sf:end-sf);                % crop the ends; dfrc at those frames would be padded
                    sw = 2 * kernelWidth^2;                 % denominator of Gaussian
                    dom = -sf:sf;                           % domain (in number of frames)
                    gauss = exp(-dom.^2/sw);                % the gaussian
                    dgauss = diff(gauss);                   % differentiating gaussian kernel to get edge detector
                    dfrc = abs(conv(frc(:,l),dgauss,'valid'));   % differentiating the force; keeping only unpadded values
                    thresh = noiseThresh*std(dfrc);         % threshold for noise
                    ffrc = (dfrc < thresh);                 % any slope below noise is plateaux
                    limits = [0,0];
                    
                    if ~exist('plateaux','var'); plateaux(1).limits = limits; end;
                    
                    for i=1:numel(ffrc)
                        if (ffrc(i) && limits(1) == 0)      % plateau and not counting yet; first frame
                            if i > sf; limits(1) = i; end;  % plateau can't start in a padded zone
                        elseif ( (ffrc(i) && i < numel(ffrc)) && limits(1) ~= 0)     % plateau and counting; add a frame
                            limits(2) = i;
                        elseif ( (~ffrc(i) || i==numel(ffrc)) && limits(1) ~= 0)    % not plateau and counting; the last frame
                            if (limits(2) - limits(1)) > minLength;                 % if plateau long enough
                                plateaux(end).limits = limits;                      % add to list
                                plateaux(end+1).limits = [0,0];                     % new default range
                            end
                            limits = [0, 0];
                        end
                    end                    
                    if numel(plateaux); plateaux(end) = []; end;         % erase the last prepared
                    
                    if limit
                        sub = (frc(:,l) < backdoorObj.contrastPlateauDetectionLimit);
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
                                hsublimplot(k).ph = ...
                                plot(hgraph, subints(k,1):subints(k,2),...
                                backdoorObj.contrastPlateauDetectionLimit*ones(1,subints(k,2)-subints(k,1)+1),...
                                'b', 'HitTest', 'off','LineWidth',2);
                                pos = [ 0.5*(subints(k,1)+subints(k,2)), backdoorObj.contrastPlateauDetectionLimit ];
                                if (mod(k,2)==0); va='bottom'; else va='top';end;
                                hsublimplot(k).txt = text( 'Parent', hgraph, 'String', strcat('[',num2str(subints(k,1)),':',num2str(subints(k,2)),']'), ...
                                'Units', 'data', 'Position', pos, 'Margin', 1,'interpreter', 'latex', ...
                                'LineStyle','none', 'HitTest','off','FontSize',10, 'Color','blue',...
                                'VerticalAlignment',va, 'HorizontalAlignment','center');
                                disp(strcat('Low contrast warning: [',num2str(subints(k,1)),',',num2str(subints(k,2)),']'));
                            end
                        end
                    end
                    
                    fitted = frc(sf:end-sf,l);  % crop the fits to match data with frames
                    for p=nextPlateau:numel(plateaux)
                        lim = plateaux(p).limits;
                        plateaux(p).avgfrc = mean( fitted(lim(1):lim(2)) );
                        if thisPlot==1 && limit    % if there's limit on contrast
                            if plateaux(p).avgfrc < backdoorObj.contrastPlateauDetectionLimit;
                                continue;   % proceed to the next plateau
                            end;
                        end;
                        hfitplot(p).ph = plot(hgraph, locint(lim(1):lim(2)), plateaux(p).avgfrc*ones(1,lim(2)-lim(1)+1), 'r', 'HitTest', 'off','LineWidth',2);
                        disp(strcat('Average plateau value [',num2str(locint(lim(1))),',',num2str(locint(lim(2))),']:',num2str(plateaux(p).avgfrc)) );
                        str = strcat(quant,num2str(round(plateaux(p).avgfrc,rnd)),units);
                        pos = [ 0.5*(locint(lim(1))+locint(lim(2))), plateaux(p).avgfrc ];
                        if (mod(p,2)==0); va='bottom'; else va='top';end;
                        hfitplot(p).txt = text( 'Parent', hgraph, 'interpreter', 'latex', 'String', str, ...
                        'Units', 'data', 'Position', pos, 'Margin', 1, ...
                        'LineStyle','none', 'HitTest','off','FontSize',10, 'FontWeight','bold','Color','red',...
                        'VerticalAlignment', va, 'HorizontalAlignment','center');
                    end     
                    nextPlateau = numel(plateaux)+1;
            end
        end
    end

    % select interval for fitting
    function fitint_callback(~,~)
        hgraph.ButtonDownFcn = [];      % suppress buttonup callback for the graph
        hfitint.String = '<HTML><center>Accept<br>Interval</HTML>';
        hfitint.Callback = 'uiresume(gcbf)';
        hold(hgraph,'on');
        BCfunction = makeConstrainToRectFcn('impoint',get(hgraph,'XLim'),get(hgraph,'YLim'));
        Ymid = (hgraph.YLim(2)+hgraph.YLim(1))*0.5;
        if isempty(fitInt)
            Xlen = hgraph.XLim(2)-hgraph.XLim(1);
            XC = [hgraph.XLim(1)+0.25*Xlen, hgraph.XLim(1)+0.75*Xlen];
        else
            XC = [max(fitInt(1,1),hgraph.XLim(1)),min(fitInt(2,1),hgraph.XLim(2))];
        end 
        intpoint(1) = impoint(hgraph,XC(1),Ymid,'PositionConstraintFcn',BCfunction);
        intpoint(2) = impoint(hgraph,XC(2),Ymid,'PositionConstraintFcn',BCfunction);
        intpoint(1).addNewPositionCallback(@(pos) fitintNewPosition_callback(pos,1));
        intpoint(2).addNewPositionCallback(@(pos) fitintNewPosition_callback(pos,2));
        uiwait(gcf);
        fitInt = round([ intpoint(1).getPosition(); intpoint(2).getPosition() ]);
        intpoint(1).delete;                 % remove points
        intpoint(2).delete;
        fitintNewPosition_callback(0,0);    % remove red lines
        hfitint.String = strcat('<HTML><center>Change<br>[',num2str(round(fitInt(1,1))),',',...
                                num2str(round(fitInt(2,1))),']</HTML>');
        hfitint.Callback = @fitint_callback;        
        hgraph.ButtonDownFcn = {@getcursor_callback};       % return the the general buttonup callback
        set([hfitline,hfitexp,hfitplateau,hplatwidth,hplatthresh,hplatmin],'Enable','on');  % activate fitting buttons
    end

    % callback called when impoint gets new position
    function fitintNewPosition_callback(coor,var)
        persistent hline;
        if isempty(hline);
            hline.ph = [];
            hline.cx = [];
            hline(2).ph = [];
            hline(2).cx = [];
        end;
        if(var==0)  % remove both
            if ~isempty(hline(1).ph); hline(1).ph.delete; end;
            if ~isempty(hline(2).ph); hline(2).ph.delete; end;
            return;
        end
        if ~isempty(hline(var).ph); hline(var).ph.delete; end;
        hline(var).ph = plot(hgraph, [coor(1), coor(1)], hgraph.YLim, 'r', 'HitTest','off');
        hline(var).cx = coor(1);
        hfitint.String = strcat('<HTML><center><font color="red">Accept<br>[',num2str(round(hline(1).cx)),',',...
                                num2str(round(hline(2).cx)),']</HTML>');
    end

    % return coordinates of cursor on the graph; delcall is only deleting
    % the marking in the graph
    function getcursor_callback(source,~,delcall)
        if ~exist('delcall','var'); delcall = false; end;   % for full calls set to false
        persistent hline;
        persistent hdot;
        if ~isempty(hline); hline.delete; end;  % delete old selection, if any
        if ~isempty(hdot); hdot.delete; end;    % delete old selection, if any
        if delcall; return; end;    % if only delete call, stop here
        hold(hgraph,'on');        
        coor = get(source, 'CurrentPoint');
        if (thisPlot == 1 || thisPlot==4 || thisPlot==5)
            if thisPlot == 1;       % contrast
                Ycoor = vidObj.getContrastByFrame(round(coor(1,1)));
            elseif thisPlot == 4;   % force
                Ycoor = BFPobj.getByFrame(round(coor(1,1)),'force');
            elseif thisPlot == 5;   % metrics
                Ycoor = BFPobj.getByFrame(round(coor(1,1)),'metric');   % returns [bead, pipette]
            end
            hline = plot(hgraph, [coor(1,1), coor(1,1)], hgraph.YLim, 'r','HitTest','off');      
            hdot = plot(hgraph, coor(1,1), Ycoor(1),'or','MarkerSize',10, 'LineWidth',2, 'HitTest','off');
            if numel(Ycoor)==2; 
                hdot(2) = plot(hgraph, coor(1,1), Ycoor(2),'or','MarkerSize',10, 'LineWidth',2, 'HitTest','off');
                disp( ['Metrics (bead,pipette): [' num2str(round(coor(1,1))),',', num2str(Ycoor(1)),',', num2str(Ycoor(2)),']'] );
            else
                disp( ['Coordinate: [' num2str(round(coor(1,1))),',', num2str(Ycoor),']'] );
            end;
            setframe(round(coor(1,1)));     % case of contrast, force, metrics
        elseif thisPlot == 3
            disp( ['Coordinate: [' num2str(coor(1,1)),',', num2str(coor(1,2)),']'] );
            hdot = plot(hgraph, coor(1,1),coor(1,2),'or','MarkerSize',10, 'LineWidth',2);
        end
        hgraph.ButtonDownFcn = {@getcursor_callback}; 
    end

    % displays report of the last tracking, illustrating poorly trackable
    % intervals, showing metrics as an overlay
    function getreport_callback(~,~)
        BFPobj.generateReport();
    end

    % selection of plotted quantity from drop-down menu
    function graphpopup_callback(source,~)
        toPlot = source.Value;
    end
       
    % set the range for plot
    function plotrange_callback(source,~,oldval,var)
       lowplot = round(str2double(hlowplot.String));
       highplot = round(str2double(hhighplot.String));
       % revert for incorrect input
       if (isnan(lowplot)||isnan(highplot)||lowplot > highplot||lowplot < 1||highplot > vidObj.Frames) 
           warndlg({'Input values must be numeric, positive, low value smaller than high value';
                    'Please correct the input and retry'},'Incorrect input', 'replace');
           source.String = num2str(oldval);
           if (var==1); lowplot = oldval;
           else highplot = oldval; end;
           return;
       end;
    end

    % plot selected quantity (numbered 1-5)
    function graphplot_callback(~,~)
        camup(hgraph,'auto');
        campos(hgraph,'auto');
        rotate3d off;
        grid(hgraph,'off');
        switch toPlot
            case 1  % contrast
                reset(hgraph);
                fitInt = [lowplot,0;highplot,0];
                getcontrast_callback(0,0);  % calls contrast procedure to calculate and plot contrast
            case 2  % tracks
                if (hgraphpip.Value || hgraphbead.Value)
                    BFPobj.plotTracks(hgraph,lowplot,highplot,logical(hgraphpip.Value),logical(hgraphbead.Value),'Style','3D');  % call plotting function with lower and upper bound
                    thisRange = [lowplot, highplot];
                    grid(hgraph,'on');
                    camup(hgraph,[-1, -1, 1]);   
                    campos(hgraph,[hgraph.XLim(2),hgraph.YLim(2),hgraph.ZLim(2)]);
                    hrot = rotate3d(hgraph);
                    hrot.Enable = 'on';
                    setAllowAxesRotate(hrot,haxes,false);
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
            case 3  % trajectories
                if (hgraphpip.Value || hgraphbead.Value)
                    BFPobj.plotTracks(hgraph,lowplot,highplot,logical(hgraphpip.Value),logical(hgraphbead.Value),'Style','2D');  % call plotting function with lower and upper bound
                    thisRange = [lowplot, highplot];
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
            case 4  % force
                BFPobj.plotTracks(hgraph,lowplot,highplot,false,false,'Style','F');
                thisRange = [lowplot, highplot];
            case 5  % metrics
                if (hgraphpip.Value || hgraphbead.Value)
                    BFPobj.plotTracks(hgraph,lowplot,highplot,logical(hgraphpip.Value),logical(hgraphbead.Value),'Style','M');
                    thisRange = [lowplot,highplot];
                else
                    warndlg('Neither pipetter nor bead tracks selected to be plotted.','Nothing to plot','replace');
                    return;
                end
        end
        thisPlot = toPlot;
        hgraph.ButtonDownFcn = {@getcursor_callback};
    end    

    % displays information about reliability of the linear approximation of
    % force-extension relation
    function lininfo_callback(~,~)
        if overLimit
            warndlg(strjoin({'The detected extensions of the RBC suggest, that the force-extension',...
                'relation might be out of the linear regime. Reliability depends on many parameters,'...
                'as a rule of a thumb,',num2str(BFPobj.linearLimit),'microns thershold was chosen.'...
                'Linear approximation tends to over-estimate the force, but even for extensions nearing'...
                'one micron, error would be around 20%. In such cases, infotext reporting stiffness is'...
                'displayed in red.'}),'RBC extension over linear limit','replace');
        else
            warndlg(strjoin({'The detected extensions of the RBC are within the boundaries of'...
                'linear approximation. In such cases, infotext reporting stiffness in displayed'...
                'in blue.'}),'RBC extension within linear limit','replace');
        end
    end

    % gets parameters for calculation, calculates (&shows) 'k', gets force
    function runforce_callback(~,~)
        persistent hanot;
        if ~isempty(hanot);hanot.delete;end;
        BFPobj.getParameters(RBCradius, CAradius, PIPradius, pressure);
        stiffness = BFPobj.k;
        stifferr  = BFPobj.Dk;
        overLimit = BFPobj.getForce(hgraph);
        hlinearinfo.Enable = 'on';
        if overLimit;colour = 'red'; else colour = 'blue';end
        strk = {strcat('$$ k = ', num2str(round(stiffness)),' \frac{pN}{\mu m}$$'),...
               strcat('$$ \Delta k = \pm' , num2str(round(stifferr)),' \frac{pN}{\mu m} $$')};
        hanot = annotation( hcalc, 'textbox', 'interpreter', 'latex', 'String', strk, ...
            'Units', 'normalized', 'Position', [0,0.67,0.5,0.15], 'Margin', 0, ...
            'LineStyle','none','FitBoxToText','on','Color',colour);
        toPlot = 4;
        thisPlot = 4;
        hgraphitem.Value = thisPlot;
        lowplot = max(hgraph.XLim(1),1);
        highplot = min(hgraph.XLim(2),BFPobj.maxFrame);
        thisRange = [lowplot,highplot];
        hlowplot.String = num2str(lowplot);
        hhighplot.String = num2str(highplot);
        hgraph.ButtonDownFcn = {@getcursor_callback};
    end

    % runs tracking procedure
    function runtrack_callback(~,~)
        BFPobj.Track(hgraph);       % run tracking
        hgraph.ButtonDownFcn = {@getcursor_callback};   % reset callback
        set([hrunforce,hgraphplot,hlowplot,hhighplot,hgraphbead,hgraphpip, hgraphitem,hreport],'Enable','on');
        toPlot = 2;
        thisPlot = 2;
        lowplot = max(BFPobj.minFrame,1);
        highplot = BFPobj.maxFrame;
        thisRange = [lowplot,highplot];
        hlowplot.String = num2str(lowplot);
        hhighplot.String = num2str(highplot);
        hgraphitem.Value = thisPlot;
    end

    % procedure to create BFPClass object, which performs all the
    % calculations
    function update_callback(~,~)
        BFPobj = BFPClass(vidObj.Name, vidObj ,intervallist);
        BFPobj.getBeadParameters(beadradius,beadbuffer,beadsensitivity,beadgradient,beadmetricthresh,P2M);
        BFPobj.getPipParameters(pipmetricthresh, contrasthresh, pipbuffer);
        set([hruntrack,hgenfilm],'Enable','on');        
    end

    % adds currently defined interval to the list of intervals
    function addinterval_callback(~,~)
        
        % check if initial frame of the interval is frame of origin of the
        % pipette pattern. This test is important to clarify, if the
        % pipette patter selected mathech the pattern of the interval
        if ( interval.frames(1) ~= tmppatframe && interval.frames(1) ~= updpatframe)
            initrackdlg = warndlg({'Selected pipette pattern does not originate at the first frame of the proposed interval';...
                     'Program will attempt to search the pattern in the frame, to verify its contrast compatibility and autoset the initial coordinates for search in this interval.'},...
                     'Remote pipette pattern','replace');
            waitfor(initrackdlg);   % wait for user to read the message
            
            [ position, ~ ] = TrackPipette( vidObj, interval.pattern, [-1 -1], [interval.frames(1) interval.frames(1)] );
            
            % draw recognized pattern on the interval first frame
            hold(haxes,'on');
            setframe(interval.frames(1));
            patrect = rectangle('Parent', haxes, 'Position', ...
                [position(2), position(1), size(interval.pattern,2), size(interval.pattern,1)],...
                'EdgeColor','r','LineWidth', 2 );
            hold(haxes,'off');
            
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
            % the same anchor and the same reference frame. Therefore, the
            % frame of origin of the pattern (tmppatframe) is localized and
            % the value 'reference' is copied. 'anchor' comes bundled with
            % the pattern information
            switch choice
                case 'Accept'
                    interval.patcoor = [position(2), position(1)];      % save the recorded position in the frame
                    hpatternint.String = strcat('[',num2str(round(interval.patcoor(1))),',',num2str(round(interval.patcoor(2))),...
                                    ';',num2str(interval.frames(1)),']');
                    tmppatframe;    % original frame of the pattern is kept, hidden;
                    updpatframe = interval.frames(1);   % but information about update is kept;
                case 'Cancel'
                    interval.patcoor = [];
                    interval.pattern = [];
                    hpatternint.String = '[.,.;.]';
                    patrect.delete; % remove rectangle
                    return;         % cancel adding interval
            end
            
            patrect.delete;
            
        end
        
        % verify if bead initial coordinate originates in the initial frame
        if ( interval.frames(1) ~= tmpbeadframe )
            warndlg({strjoin({'Initial frame of the interval does not match the frame of origin of initial bead coordinates.',...
                'The initial bead coordinate must be specified for the interval initial frame.'});...
                'Please make the necessary corrections and try again.'},...
                'Bead frame mismatch', 'replace');
            return;
        end;
        
        % verify all the necessary fields exist and are filled
        for f=1:numel(intfields);
            if (~isfield(interval,intfields{f}) || isempty(interval.(intfields{f})))
                warndlg(strcat('The field ', intfields{f}, ' is missing or empty. Provide all the required information.'),...
                        'Field missing','replace');
                return;
            end
        end
        
        % verify the values of the interval and refframes
        if ~(isinvideo(interval.frames(1)) && isinvideo(interval.frames(2)) && isinvideo(interval.reference))
            warndlg(strjoin({strcat('One or more of the specified frames, first frame (', num2str(interval.frames(1)),'), ',...
                                                                       'or last frame (', num2str(interval.frames(2)),'), of the interval,'),...
                    strcat('or reference frame (', num2str(interval.reference), ')'),...
                    strcat('have incorrect value, or value out of bounds of the video: [1,',num2str(vidObj.Frames),'].'),...
                    'Please review the values and try to add the interval again.'}));
            return;
        end
        
        % verify intervals do not overlap
        if numel(intervallist) > 0;
            review = false;     % flag for abort and review, if intervals partially overlap
            modified = false;
            for i=1:numel(intervallist)
                if (interval.frames(1) < intervallist(i).frames(2) &&...
                    interval.frames(2) > intervallist(i).frames(1))
                
                    old = [interval.frames(1), interval.frames(2)]; % save original timespan
                    if interval.frames(1) >= intervallist(i).frames(1);
                        interval.frames(1) = max(interval.frames(1),intervallist(i).frames(2));
                        modified = ~modified;   % toggle
                    end
                    if interval.frames(2) <= intervallist(i).frames(2)
                        interval.frames(2) = min(interval.frames(2),intervallist(i).frames(1));
                        modified = ~modified;
                    end
                    
                    hstartint.String = interval.frames(1);
                    hendint.String = interval.frames(2);
                    if modified;    % only one limit was changed, i.e. intervals are not mutual subsets
                        warndlg({strcat('Added interval [',num2str(old(1)),',',num2str(old(2)),...
                                '] overlaps with another existing interval, [', num2str(intervallist(i).frames(1)),',',...
                                num2str(intervallist(i).frames(2)),'].');...
                                strcat('Please note intervals should be exclusive. New interval was modified to [',...
                                num2str(interval.frames(1)),',',num2str(interval.frames(2)),']. Please review and submit again.')},...
                                'Overlapping intervals','replace');
                        review = true;
                    else
                        warndlg({strcat('Added interval [',num2str(old(1)),',',num2str(old(2)),...
                                '] is subset or superset of another existing interval, [', num2str(intervallist(i).frames(1)),',',...
                                num2str(intervallist(i).frames(2)),']. Please review.')},...
                                'Duplcite intervals', 'replace');
                        interval.frames = old;  % reset original values
                        hstartint.String = old(1);
                        hendint.String = old(2);
                        return; % if interval is subset of another interval, abort immediatelly
                    end    
                end
            end
            if review; return; end; % after overlaps are sorted out, let user review
        end
    
        % verify reference point is part of interval being added; in
        % case reference is external, issue contrast change risk warning;
        % the pipette must be local for this interval
        if ( interval.reference >= interval.frames(1) && interval.reference <= interval.frames(2) ) && ...
           ( tmppatframe >= interval.frames(1) && tmppatframe <= interval.frames(2) );
            passed = true;  % eligible reference frame
        elseif ( interval.reference >= interval.frames(1) && interval.reference <= interval.frames(2) )
            hw = warndlg({'The pipette pattern originates in another interval, but the reference frame originates in this interval.';...
                     'It is allowed and common, but make sure the frame of reference has a compatible contrast and uses the same pipette pattern as in this interval.'},...
                     'External reference frame','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        elseif ( tmppatframe >= interval.frames(1) && tmppatframe <= interval.frame(2) )
            hw = warndlg({'The reference frame does not belong to the added interval, but the pipette pattern originates in this interval.';...
                     'It is allowed and common, but make sure the frame of reference has a compatible contrast and uses the same pipette pattern as in this interval.'},...
                     'External reference frame','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        else
            hw = warndlg({'The reference frame does not belong to the added interval and neither does pipette pattern originate in the interval.';...
                     'It is allowed and common, but make sure the frame of reference has a compatible contrast and uses the same pipette pattern as in this interval.'},...
                     'External reference frame','replace');
            passed = false; % so far uneligible, run further tests
            uiwait(hw);
        end;
        
        % compare the reference used with the reference at the interval of
        % origin of the pipette pattern
        if ~passed
            rframe = (getreference(tmppatframe));
            if (rframe == interval.reference);  % let pass                
            else
                choice = questdlg(strjoin({'The reference frame (i.e. zero-strain frame) You chose,',num2str(interval.reference),',is different from the reference frame',...
                    'of original interval of the pattern,', num2str(rframe),'. This may be a false warning, but please make sure,',...
                    'that the pattern and the reference distance are compatible over the two intervals, in order to get compatible force readings.'}),...
                    'Reference incompatibility between intervals','Keep','Review','Keep');
                switch choice
                    case 'Keep';    % let pass
                    case 'Review'
                        return;
                end
            end
        end
        
        % finally, if reference frame be not part of analysis, abort
        if ~(logical(getreference(interval.reference))) &&...
           (interval.reference < interval.frames(1) || interval.reference > interval.frames(2));
            warndlg(strcat('Selected reference (zero strain) frame, ', num2str(interval.reference),...
                ', does not belong to any present interval, neither to interval being added. ',...
                'Please select a reference point, which is part of tracking.',...
                'The adding will abort.'),...
                'Unaccessible reference point', 'replace');
            return;
        end
        
        % if all checks are passed, add interval to the list and report to
        % the table of intervals;
        intervallist = strucopy(intervallist,interval);

        makeTab();  % call external function to generate the table from the intervallist
           
        % clear interval to be reused; clear UI data; clear temp. variables
        interval = struct('frames',[0,0]);
        hstartint.String = [];
        hendint.String = [];
        hrefframe.String = [];
        hpatternint.String = '[.,.;.]';
        hbeadint.String = '[.,.;.]';
        hpatsubcoor.String = '[.,.]';
        updpatframe = 0;
        
        % disable the buttons
        hgetpattern.Enable = 'off';
        hselectpat.Enable = 'off';
        hshowpattern.Enable = 'off';
        hgetpatsubcoor.Enable = 'off';
        haddinterval.Enable = 'off';
        hgetrefframe.Enable = 'off';
        
        % enable Update button
        hupdate.Enable = 'on';
    
    end

    % selects table lines (intervals from intervallist) to be removed
    function rmtabledint_callback(hT, data)
        row = data.Indices(1);
        col = data.Indices(2);
        if data.EditData            % selected for removal
            remove(end+1) = row;    % get selected row for removal
            hT.Data{row,col} = true;
        else
            [is,ind] = find(remove==row);
            if is; remove(ind) = []; end;   % remove the index
            hT.Data{row,col} = false;
        end
        
        if numel(remove) > 0; heraseint.Enable = 'on';
        else heraseint.Enable = 'off'; end
        
    end

    % removes all selected entries from the interval list and the table
    function eraseint_callback(~,~)
        if numel(remove) > 0;
            remove = sort(remove,'descend');    % the elements are deleted from the end            
            
            for ind=1:numel(remove)             % remove intervals from the list
                intervallist(remove(ind)) = [];
            end
            
            remove = [];                        % erase remove list
            heraseint.Enable = 'off';           % switch off the button
            
            makeTab();      % remake table of intervals
        end
    end

    % allows to select the pattern anchor
    function getpatsubcoor_callback(~,~)        
        if ~isfield(interval,'pattern');
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
        hpatfig  = figure;  % create new figure with a button, displaying the pattern
        hpataxes = axes('Parent',hpatfig, 'Units','normalized','Position',[0,0.2,1,0.8]);
        imagesc(interval.pattern, 'Parent',hpataxes);
        colormap(gray);
        axis(hpataxes,'image');
        haccept = uicontrol('Parent',hpatfig, 'Style', 'pushbutton', 'String', 'Accept',...
                'Units','normalized','Enable','off','Position',[0.2,0,0.2,0.15],'Callback','uiresume(gcbf)');
        BCfunction = makeConstrainToRectFcn('impoint',get(hpataxes,'XLim'),get(hpataxes,'YLim'));
        beadpoint = impoint(hpataxes,'PositionConstraintFcn', BCfunction);
        haccept.Enable = 'on';
        uiwait(gcf);
        subcoor = (beadpoint.getPosition);
        beadpoint.delete;
        hpatsubcoor.String = strcat('[',num2str(round(subcoor(1))),',',num2str(round(subcoor(2))),']');
        interval.patsubcoor = subcoor;
        close(hpatfig);
    end
        
    % set current frame to the first frame of the interval
    function gotointframe_callback(~,~)
        setframe(interval.frames(1));
    end

    % saves the currently open bead for this interval to track
    function getintbead_callback(~,~)
        % check if there is a bead in the list to add
        if numel(beadlist)==0 || isempty(beadlist(hbeadinilist.Value));
            warning('No bead has been added to the list');
            return;
        end;
        
        val = hbeadinilist.Value;
        if interval.frames(1) ~= beadlist(val).frame
            choice = questdlg(strjoin({'The frame of origin of the selected bead',...
                'does not match the initial frame of the interval. You can update the initial frame,',...
                'cancel and choose another bead from the list, or select the bead directly on the screen.'}),...
                'Frame mismatch','Update','Cancel','Select','Update');
            switch choice
                case 'Update'
                    hstartint.String = num2str(beadlist(val).frame);
                    interval.frames(1) = beadlist(val).frame;
                case 'Cancel'
                    return;
                case 'Select'
                    selectintbead_callback(hselectbead,0);
                    return;
            end
        end
        bead = beadlist(val);
        interval.contrast = beadlist(val).contrast;
        interval.beadcoor = beadlist(val).coor;
        tmpbeadframe = beadlist(val).frame;
        hbeadint.String = strcat('[',num2str(round(interval.beadcoor(1))),',',num2str(round(interval.beadcoor(2))),...
                                    ';',num2str(tmpbeadframe),';',interval.contrast,']');
        hgetpattern.Enable = 'on';
        hselectpat.Enable = 'on';
    end


    % saves the currently open pattern for this interval to track
    function getintpat_callback(~,~)
        % check if there's a pattern in the list to add
        if numel(patternlist)==0 || isempty(patternlist(hpatternlist.Value))
            warning('No pipette pattern in the list');
            return;
        end
        
        val = hpatternlist.Value;
        pattern = patternlist(val);         % set last added pattern 
        tmppatframe = patternlist(val).frame;
        interval.pattern = patternlist(val).cdata;
        interval.patcoor = patternlist(val).coor;
        interval.patsubcoor  = patternlist(val).anchor;        
        interval.reference = getreference(tmppatframe);
        hrefframe.String = interval.reference;
        hpatsubcoor.String = strcat('[',num2str(round(interval.patsubcoor(1))),','...
                            ,num2str(round(interval.patsubcoor(2))),']');
        hpatternint.String = strcat('[',num2str(round(interval.patcoor(1))),',',num2str(round(interval.patcoor(2))),...
                                    ';',num2str(tmppatframe),']');
        hgetpatsubcoor.Enable = 'on';
        hshowpattern.Enable = 'on';
        haddinterval.Enable = 'on';
        hgetrefframe.Enable = 'on';
    end
                
    % displays the pattern selected for the given interval
    function [hpatfig,hpataxes] = showintpattern_callback(~,~)
        if ~isfield(interval,'pattern');
            warndlg('Nothing to show. Choose a pipette pattern first','No pipette pattern selected','replace');
            return;
        end;
        hpatfig  = figure;  % open new figure
        hpataxes = axes('Parent',hpatfig);
        imagesc(interval.pattern, 'Parent',hpataxes);   % display image (imagesc scales also intensity range)
        colormap(gray);                                 % grayscale image
        axis(hpataxes,'image');        
        if isfield(interval,'patsubcoor')
            viscircles(hpataxes,interval.patsubcoor,1,'EdgeColor','b');
        end;
    end

    % get reference frame from the current frame
    function getrefframe_callback(~,~)
        interval.reference = getreference(tmppatframe);
        hrefframe.String = num2str(interval.reference);
    end

    % set reference frame, where the RBC is not strained
    function setrefframe_callback(source,~,oldval)
        val = round(str2double(source.String));
        if (isnan(val) || val < 1 || val > vidObj.Frames)
            warndlg({'Input must be a positive number within the video limits.';'Input is rounded.'},...
                     'Incorrect input','replace');
            source.String = num2str(oldval);
            interval.reference = [];        % set to non-input
            return;
        end                 
        interval.reference = val;
        hrefframe.String = num2str(val);
    end

    % set the range of frames to track
    function setintrange_callback(source,~,oldval,num)
        in = str2double(source.String);
        if (isnan(in) || in < 1 || in > vidObj.Frames)
            warndlg({'Input must be a positive number within the video limits.';'Input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = [];
            interval.frames(num) = oldval;
            return;
        end
        low  = round(str2double(hstartint.String));
        high = round(str2double(hendint.String));
        if (low > high)
            warndlg('The input range is empty.', 'Incorrect input','replace');
        end
        interval.frames = [low,high];
        hgetbead.Enable = 'on';
    end

    % measure radius of the pipette
    function measureLength_callback(source,~,type)
        if verbose;
            msgOptions.Interpreter = 'Latex';
            msgOptions.WindowStyle  = 'modal';
            msgbox(strjoin({'Select the {\bfseries diameter} of the', type}),'Radius measurement', msgOptions);
        end
        BCfunction = makeConstrainToRectFcn('imline',get(haxes,'XLim'),get(haxes,'YLim'));
        line = imline(haxes,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        LineEnds = line.getPosition;
        line.delete;
        length_ = norm( LineEnds(1,:)-LineEnds(2,:) );
        if strcmp(type,'pipette')
            PIPradius = 0.5*length_*P2M;
            hPIPrad.String = num2str(round(PIPradius,2));
        else
            CAradius = 0.5*length_*P2M;
            hCArad.String = num2str(round(CAradius,2));
        end        
        source.Callback = {@measureLength_callback,type};
        str = strjoin({type,'radius'});
        str(1) = upper(str(1));
        source.String = str;
    end

    % detects the RBC and measures its radius
    function measureRBC_callback(source,~)
        BCfunction = makeConstrainToRectFcn('impoint',get(haxes,'XLim'),get(haxes,'YLim'));
        RBCpoint = impoint(haxes,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        RBCinicoor = (RBCpoint.getPosition);
        RBCframe = round(vidObj.CurrentFrame);
        RBCpoint.delete;
        RBCcontrast = questdlg('Does the red blood cell appear bright or dark?','RBC contrast','bright','dark','bright');
        [RBCcoor,RBCradius_,~,~] = TrackBead(vidObj,RBCcontrast,RBCinicoor,[RBCframe,RBCframe],...
            'radius',[20,30], 'sensitivity',0.95,'edge',0.1);
        hRBCshow = viscircles(haxes,[RBCcoor(2),RBCcoor(1)],RBCradius_);
        found = questdlg('Was the RBC detected correctly?','Confirm RBC detection','Accept','Cancel','Accept');
        if strcmp(found, 'Accept')
            RBCradius = RBCradius_*P2M;
            hRBCrad.String = num2str(round(RBCradius,2));
        end        
        source.Callback = {@measureRBC_callback};
        source.String = 'RBC radius';
        pause(2);
        hRBCshow.delete;       % delete the bead outline
    end

    % set experimental parameters; validate input
    function setexpdata_callback(source,~,oldval)
        input = str2double(source.String);
        if isnan(input)
            source.String = num2str(oldval);
            warndlg('Input must be of type double','Incorrect input', 'replace');
            return;
        end
        pressure = str2double(hpressure.String);
        RBCradius = str2double(hRBCrad.String);
        PIPradius = str2double(hPIPrad.String);
        CAradius = str2double(hCArad.String);
        P2M = str2double(hP2M.String);
    end

    % set pipette tracking grace period
    function pipbuffer_callback(source,~)
        val = str2double(source.String);
        if isnan(val) || val < 0
            warndlg({'The grace period must be a positive number.';'Non-integer input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = num2str(pipbuffer);
            return;
        end
        pipbuffer = round(val);
        source.String = num2str(pipbuffer);
    end

    % set contrast threshold value
    function pipcontrast_callback(source,~)
        contrasthresh = source.Value;
        hcontrasthreshtxt.String = {'Contrast';strjoin({'thresh:', num2str(round(contrasthresh,2))})};
    end

    % set correlation threshold for the pipette pattern detection
    function pipmetric_callback(source,~)
        pipmetricthresh = source.Value;
        hcorrthreshtxt.String = {'Correlation';strjoin({'thresh:', num2str(round(pipmetricthresh,2))})};
    end

    % set detection metric threshold, values are usually between (0,2)
    function beadmetric_callback(source,~)
        beadmetricthresh = source.Value;
        hmetrictxt.String = {'Metric'; strjoin({'thresh:', num2str(round(beadmetricthresh,2))})};
    end

    % set circle detection gradient threshold
    function beadgrad_callback(source,~)
        beadgradient = source.Value;
        hgradtxt.String = {'Gradient: '; num2str(round(beadgradient,2))};
    end
    
    % set circle detection sensitivity
    function beadsensitivity_callback(source,~)
        beadsensitivity = source.Value;
        hsensitivitytxt.String = {'Sensitivity: '; num2str(round(beadsensitivity,2))};
    end
    
    % set bead tracking grace period
    function setbuffer_callback(source,~)
        val = str2double(source.String);
        if isnan(val) || val < 0
            warndlg({'The grace period must be a posivite number.';'Non-integer input is rounded.'},...
                    'Incorrect input', 'replace');
            source.String = num2str(beadbuffer);
            return;
        end
        beadbuffer = round(val);
        source.String = num2str(beadbuffer);
    end

    % set limit on radius for the bead tracking; verify correct input
    function setrad_callback(~,~)
        vmin = str2double(hminrad.String);
        vmax = str2double(hmaxrad.String);
        if (isnan(vmin) || isnan(vmax))     % abort if input is incorrect
            warndlg('Input must be of type double', 'Incorrect input', 'replace');
            hminrad.String = num2str(beadradius(1));
            hmaxrad.String = num2str(beadradius(2));
            return;
        end
        beadradius(1) = vmin;
        beadradius(2) = vmax;
        if (beadradius(1) > beadradius(2))  % warn if input gives empty range
            warndlg('Lower bead radius limit is larger than the upper limit',...
                'Empty radius range', 'replace');
        end
    end


    % add the selected bead coordinate to list
    function addbead_callback(~,~)
        if isempty(lastlistbead);
            warning('No bead to add');
            return;
        end;
        beadlist = strucopy(beadlist,lastlistbead);     % push back bead to the beadlist
        ind = numel(beadlist);
        hbeadinilist.String(ind) = {strcat('[',num2str(round(lastlistbead.coor(1))),',',num2str(round(lastlistbead.coor(2))),';',...
                                    num2str(lastlistbead.frame),';',lastlistbead.contrast,']')};
        hbeadinilist.Value = ind;
    end

    % drop-down menu to choose one of the bead initial coors
    function pickbead_callback(source,~)
        val = source.Value;
        bead = beadlist(val);                
    end

    % remove selected bead coordinate from the list
    function rmbead_callback(~,~)
        val = hbeadinilist.Value;
        num = numel(beadlist);
        if (num == 0)
            return;
        elseif (num == 1)
            hbeadinilist.String(1) = {'no data'};
            hbeadinilist.Value = 1;
            beadlist(num) = [];
        elseif (val == num)
            hbeadinilist.String(val) = [];
            beadlist(val) = [];
            hbeadinilist.Value = val-1;
        else
            hbeadinilist.String(val) = [];
            beadlist(val) = [];
        end
    end

    % button adds current pattern to the pattern list
    function addpattern_callback(~,~)
        if isempty(lastlistpat);
            warning('No pattern to add');
            return;
        end;
        patternlist = strucopy(patternlist,lastlistpat);    % adds new pattern to the end of the list
        ind = numel(patternlist);
        hpatternlist.String(ind) = {strcat('[',num2str(round(lastlistpat.coor(1))),',',num2str(round(lastlistpat.coor(2))),';',...
                                    num2str(lastlistpat.frame),']')};
        hpatternlist.Value = ind;
    end

    % button removes current pattern from the pattern list
    function rmpattern_callback(~,~)
       val = hpatternlist.Value;
       num = numel(patternlist);
       if (num == 0)    % case of nothing to remove
           return;
       elseif (num == 1)    % removing the last one; replace name with 'nodata'
           hpatternlist.String(1) = {'no data'};
           hpatternlist.Value = 1;
           patternlist(val) = [];
       elseif (val == num)  % removing last entry in the list; shift left
           hpatternlist.String(val) = [];
           patternlist(val) = [];
           hpatternlist.Value = val-1;
       else                 % general remove; shifts by itself
           hpatternlist.String(val) = [];
           patternlist(val) = [];
       end
    end
        
    % drop-down menu to choose one of the patterns
    function pickpattern_callback(source,~)
        val = source.Value;
        setpattern(patternlist(val));                
    end

    % select the centre of the bead as a seed for tracking
    function getpoint_callback(source,~,srctag)
        
        % check if there's no other selection under way
        if selecting
            warning(selectWrng);
            return;
        else
            selecting = true;
        end
            
        [bead,pass] = getBead(source,srctag);  % call method to detect bead
        
        % if detection fails (reject or error), old 'bead' value is returned
        % if old value is empty, stop here, do not change anything
        if isempty(bead) || ~pass; 
            selecting = false;
            return; 
        end;  
            
        % only if meaningful bead selection was returned, continue
        switch srctag
            case 'list'     % call source is list
                lastlistbead = bead;
                hbeadcoortxt.String = strcat('[',num2str(round(bead.coor(1))),',',num2str(round(bead.coor(2))),...
                                        ';',num2str(bead.frame),']');
            case 'interval' % call source is direct interval bead detection
                if (interval.frames(1) ~= bead.frame)
                    warning(strjoin({'Initial frame of current tracking interval was changed',...
                            'to the frame of bead selection. If You wish to preserve Your interval,',...
                            'reselect the bead in the appropriate frame.'}));
                    interval.frames(1) = bead.frame;
                    hstartint.String = num2str(round(interval.frames(1)));
                end;
                if (interval.frames(2) == 0 || interval.frames(2) < interval.frames(1))
                    warning(strjoin({'Final frame of current tracking interval was invalid',...
                        'and was changed. The final frame must not precede the initial.'}));
                    interval.frames(2) = interval.frames(1);
                    hendint.String = num2str(round(interval.frames(2)));
                end;
                interval.beadcoor = bead.coor;
                interval.contrast = bead.contrast;
                hbeadint.String = strcat('[',num2str(round(interval.beadcoor(1))),',',num2str(round(interval.beadcoor(2))),...
                                        ';',num2str(interval.frames(1)),']');
                tmpbeadframe = interval.frames(1);
                hgetpattern.Enable = 'on';
                hselectpat.Enable = 'on';
        end
       
        selecting = false;  % release detection lock
        
    end
        
    % allows user to select rectangular ROI as a pattern file
    function getrect_callback(source,~,srctag)
        
        % check if no other selection process is running
        if selecting
            warning(selectWrng);
            return;
        else
            selecting = true;
        end
        
        [pattern,pass] = getPattern( source, srctag);
        
        if isempty(pattern) || ~pass; 
            selecting = false;
            return; 
        end;  
        
        switch srctag
            case 'list'
                lastlistpat = pattern;
                hpatcoortxt.String = strcat( '[',num2str(round(pattern.coor(1))),',',num2str(round(pattern.coor(2))),';',...
                num2str(pattern.frame),']');
                setpattern(pattern);
            case 'interval'
                interval.pattern = pattern.cdata;
                interval.patcoor = pattern.coor;
                tmppatframe = pattern.frame;
                interval.reference = getreference(pattern.frame);
                interval.patsubcoor = pattern.anchor;
                hrefframe.String = interval.reference;
                hpatternint.String = strcat('[',num2str(round(interval.patcoor(1))),',',num2str(round(interval.patcoor(2))),...
                                        ';',num2str(tmppatframe),']');
                hpatsubcoor.String = strcat('[',num2str(round(interval.patsubcoor(1))),','...
                                ,num2str(round(interval.patsubcoor(2))),']');
        end
        
        selecting = false;
                
    end

    % set video path by typing it in
    function videopath_callback(source,~)
        videopath = source.String;
    end        

    % browse button to chose the file
    function browsevideo_callback(~,~)
        [filename, pathname] = uigetfile({'*.avi;*.mp4;*.tiff;*tif','Video Files (*.avi,*.mp4,*.tiff)'},...
                                'Select a video file',videopath);
        if ~isequal(filename, 0)     % test validity of selected file; returned 0 if canceled
            videopath = strcat(pathname,filename);
            hvideopath.String = videopath;
            openvideo_callback;
        end
    end

    % sets frame rate of the output generated video
    function outvideo_callback(source,~,failsafe,var)
        val = round(str2double(source.String));
        if (isnan(val) || val < 1)
            warndlg('The input must be a positive number.','Incorrect input','replace');
            source.String = num2str(failsafe);
            return;
        end
        if (var == 1)
            outframerate = val;
        elseif (var == 2)
            outsampling = val;
        end
        
        source.String = num2str(val);   % in case of rounding
    end

    % generate an external video file of original film overlaid with
    % tracking marks
    function generatefilm_callback(~,~)
        BFPobj.generateTracks('Framerate',outframerate,'Sampling',outsampling);
    end

    % whether to display or not the tracking data results
    function disptrack_callback(source,~)
        disptrack = source.Value;
    end

    % plot the contrast progress of the video
    function getcontrast_callback(~,~)
        % if video is long
        if vidObj.Frames > 1000 && verbose && numel(vidObj.Contrast) ~= vidObj.Frames
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
        [ contrast, ~ ] = vidObj.getContrast;    % calculates and saves in video object, if not yet calculated
        if(toPlot~=1)
            lowplot = 1;                % initial frame
            highplot = vidObj.Frames;   % final frame
        end
        cla(hgraph);                % clear current graph
        hold(hgraph,'on');
        hconplot  = plot(hgraph,lowplot:highplot,contrast(lowplot:highplot),'r','HitTest','off');
%        hgrayplot = plot(hgraph,lowplot:highplot,gray(lowplot:highplot), 'b', 'HitTest','off');
        xlim(hgraph,[lowplot,highplot]);    % avoid margins around the graph
        thisRange = [lowplot,highplot];     % range of the current plot
        thisPlot = 1;                       % currently plotted contrast flag
        hgraphplot.Enable = 'on';           % allow plot button, contrast only
        set( hlowplot,  'Enable','on', 'String', num2str(lowplot)  );
        set( hhighplot, 'Enable','on', 'String', num2str(highplot) );        
%        legend(hgraph,'contrast','mean gray');
        legend(hgraph,'contrast');
        
        % find plateaux and report 'safe' and 'unsafe' intervals
        % these parameters can be backdoored;
        % sensitivity, threshold, duration and minimal contrast. The results are only
        % informative, so user should need to change them. More
        % sophisticated analysis can be done using adaptive plateaux
        % fitting.
        
        % save default values suitable for force plateaux detection
        defaults = [ kernelWidth, noiseThresh, minLength ];
        
        kernelWidth = backdoorObj.contrastPlateauDetectionSensitivity;
        noiseThresh = backdoorObj.contrastPlateauDetectionThreshold;
        minLength   = backdoorObj.contrastPlateauDetectionLength;
        
        fit_callback(0,0,'plat',true);
        
        % restore defaults
        [kernelWidth] = defaults(1);
        [noiseThresh] = defaults(2);
        [minLength]   = defaults(3);
        
        if verbose;
            helpdlg(strjoin({'Contrast analysis has finished. The detected plateaux (in red) are the safest',...
                'intervals for tracking. Drop in contrast of more than',num2str((1-backdoorObj.contrastPlateauDetectionLimit)*100),'%',...
                'off maximum is designated (if detected) in blue. Those intervals might be unsuitable for tracking.'}),...
                'Contrast analysis finished');
        end
        
        hgraph.ButtonDownFcn = {@getcursor_callback};
    end

    % sets frame input into edit field after pressing a button
    function gotoframe_callback(~,~)
        % temporary edit field
        hsetframe = uicontrol('Parent',husevideo, 'Style','edit', 'Units', 'normalized',...
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
        playing = true;
        hplaybutton.String = 'Stop';
        hplaybutton.Callback = {@stopvideo_callback};
        while ((vidObj.CurrentFrame + rate <= vidObj.Frames && vidObj.CurrentFrame + rate > 0) && playing)
            setframe(vidObj.CurrentFrame+rate);     
            pause(1);
        end        
        hplaybutton.String = 'Play';

    end

    % stops the video play
    function stopvideo_callback(~,~)
        playing = false;
        hplaybutton.String = 'Play';
        hplaybutton.Callback = {@playvideo_callback};
    end

    % open video and set its parameters where necessary
    function openvideo_callback(~,~)
        vidObj = vidWrap(videopath);
        frame = struct('cdata', zeros(vidObj.Height,vidObj.Width, 'uint16'), 'colormap', []);
        hmoviebar.Enable = 'on';
        hmoviebar.Min = 1;
        hmoviebar.Max = vidObj.Frames;
        hmoviebar.Value = vidObj.CurrentFrame;
        hmoviebar.SliderStep = [ 1/vidObj.Frames, 0.1 ];
        setframe(1);
        setvidinfo();
        setvidinterval();
        set([hdispframe,hstartint,hendint,hshowframe,hrefframe],'Enable','on');
        set([hplaybutton,hrewindbtn,hffwdbutton,hcontrast],'Enable','on');
    end

    % set position in the video
    function videoslider_callback(source,~)
        setframe(source.Value);
    end
% ==================================================================
%   ======================== HELPER FUNCTIONS ======================
   
    % detect and return pipette pattern
    function [ patinfo,pass ] = getPattern( source, tag )
        
        patinfo = struct('coor',[],'frame',[],'reference',[], 'cdata', [], 'anchor', []);
        BCRfunction = makeConstrainToRectFcn('imrect',haxes.XLim,haxes.YLim);
        rectangle = imrect(haxes,'PositionConstraintFcn',BCRfunction);              % interactive ROI selection
        source.String = 'Confirm';         % update UI to confirm selection
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);   
        
        try 
            dcoor = rectangle.getPosition;  % vector of 4 coordinates; doubles
            icoor = round(dcoor);
            roi = [ max(icoor(2),1), min(icoor(2)+icoor(4),vidObj.Height);...       % ROI in the image
                    max(icoor(1),1), min(icoor(1)+icoor(3),vidObj.Width) ];         % construct coors of ROI
            patinfo.cdata = frame.cdata(roi(1,1):roi(1,2),roi(2,1):roi(2,2),:);   % copy the selected image  
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
                        interval.pattern = patinfo.cdata;
                        [hf,hax] = showintpattern_callback();
                    else
                        hax = hminiaxes;
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

            hgetpatsubcoor.Enable = 'on';
            hshowpattern.Enable = 'on';
            haddinterval.Enable = 'on';
            hgetrefframe.Enable = 'on';
            pass = true;
            
        catch
            warning(strjoin({'An error occured during pattern selection callback,',...
                'it was probably interrupted by another function or action.',...
                'Please try again, without any intermittent action.'}));
            rectangle.delete;
            patinfo = pattern;
            pass = false;
            
        end
        
        source.String = 'Select';
        source.Callback = {@getrect_callback, tag};
        
    end


    % detect and return bead information
    function [ beadinfo,pass ] = getBead( source,tag )
        
        beadinfo = struct('coor',[],'frame',[],'contrast',[]);
        % intial section, set boundary, select point, change UI, wait for
        % confirmation of the selection
        BCfunction = makeConstrainToRectFcn('impoint',get(haxes,'XLim'),get(haxes,'YLim'));
        beadpoint = impoint(haxes,'PositionConstraintFcn',BCfunction);
        source.String = 'Confirm';
        source.Callback = 'uiresume(gcbf)';
        uiwait(gcf);
        
        try
            beadinfo.coor = beadpoint.getPosition;
            beadinfo.frame= round(vidObj.CurrentFrame);
            choice = questdlg('Select bead contrast','Bead contrast','Bright','Dark','Dark');
            switch choice
                case 'Bright'
                    beadinfo.contrast = 'bright';
                case 'Dark'
                    beadinfo.contrast = 'dark';
            end;
            beadpoint.delete;
            [coor,rad] = TrackBead(vidObj, beadinfo.contrast, beadinfo.coor,...
                         [ beadinfo.frame, beadinfo.frame ] );  % try to detect the bead in the frame
            hcirc = viscircles(haxes,[ coor(2), coor(1) ], rad, 'EdgeColor','r');    % plot the detected bead
            choice = questdlg('Was the bead detected correctly?','Confirm selection','Accept','Reject','Accept');
            switch choice
                case 'Accept'   % precise the coordinate
                    beadinfo.coor = coor;
                    pass = true;
                case 'Reject'
                    beadinfo = bead;
                    pass = false;
            end;
            hcirc.delete;
        catch
            warning(strjoin({'An error occured during bead selection callback,',...
                'it was probably interrupted by another function or action.',...
                'Please try again, without any intermittent action.'}));
            beadpoint.delete;
            beadinfo = bead;
            pass=false;
        end
        
        source.String = 'Select';
        source.Callback = {@getpoint_callback,tag};                     
                     
    end


    % selects pattern
    function [] = setpattern(pattern_in)
       pattern = pattern_in;
       imagesc(pattern.cdata, 'Parent', hminiaxes);  % display the cut in the special window
       axis(hminiaxes, 'image','off');    
    end

    % returns current frame number; can be changed to more complex and
    % failsafe behaviour (now's just ridiculous, I know)
    function [currentFrame] = getFrame()
        currentFrame = vidFrameNo;
    end

    % sets the GUI to the given frame number
    function [] = setframe(frameNo)
        vidFrameNo = round(frameNo);
        frame = vidObj.readFrame(vidFrameNo);
        hdispframe.String = strcat(num2str(vidFrameNo),'/', num2str(vidObj.Frames));
        hmoviebar.Value = vidObj.CurrentFrame;        
        imagesc(frame.cdata, 'Parent', haxes);
        colormap(gray);        
        axis(haxes, 'image');
        if disptrack
            hold(haxes, 'on')
            for i=1:numel(BFPobj.intervallist);
                if( vidFrameNo >= BFPobj.intervallist(i).frames(1) && ...
                    vidFrameNo <= BFPobj.intervallist(i).frames(2) )
                    coorind = vidFrameNo - BFPobj.intervallist(i).frames(1) + 1;
                    viscircles(haxes,[ BFPobj.pipPositions(i).coor(coorind,2)/P2M,... 
                                       BFPobj.pipPositions(i).coor(coorind,1)/P2M ],...
                               5, 'EdgeColor','b');   % plot pipette
                    viscircles(haxes,[ BFPobj.beadPositions(i).coor(coorind,2)/P2M,... 
                                       BFPobj.beadPositions(i).coor(coorind,1)/P2M ],...
                               BFPobj.beadPositions(i).rad(coorind)/P2M, 'EdgeColor','r');  % plot bead
                    break; % do not continue once plotted
                end
            end
        end
    end

    % populates the video information pannel
    function setvidinfo()
        hvidwidth.String = strcat('Width: ',num2str(vidObj.Width),' px');
        hvidheight.String = strcat('Height: ',num2str(vidObj.Height),' px');
        hvidframes.String = strcat('Frames: ',num2str(vidObj.Frames));
        hvidname.String = strcat('Name: ', vidObj.Name);
        hvidformat.String = strcat('Format: ', vidObj.Format);
        if ~vidObj.istiff
            hvidframerate.String = strcat('Framerate: ',num2str(vidObj.Framerate), ' fps');
            hvidduration.String = strcat('Duration: ',num2str(vidObj.Duration),' s');
        end
    end

    % sets fields during opening of the video
    function setvidinterval()
        interval.frames(1) = 1;
        interval.frames(2) = vidObj.Frames;
        hstartint.String = num2str(1);
        hendint.String = num2str(vidObj.Frames);
        hgetbead.Enable = 'on';
        hselectbead.Enable = 'on';
    end
    
    % copy structure into an empty target
    function outlist = strucopy(outlist,item)
        size = numel(outlist);
        names = fieldnames(item);
        for i=1:numel(names)
            outlist(size+1).(names{i}) = item.(names{i});
        end
    end
    
    % searches original reference frame selected for the interval of origin
    % origframe: frame of origin of the pipette pattern
    function [rframe] = getreference(orgiframe)
        rframe = 0;     % return zero, if original reference cannot be found
        if numel(intervallist) > 0        
            for i=1:numel(intervallist)
                if orgiframe >= intervallist(i).frames(1) && orgiframe <= intervallist(i).frames(2)
                    rframe  = intervallist(i).reference;        % this is the reference distance
                    break;
                end
            end
        else
            rframe = vidObj.CurrentFrame;   % if this is the first interval, use current frame
        end
    end

    % check if this frame is part of the video
    function [ is ] = isinvideo(frame)
        is = ( frame > 0 && frame <= vidObj.Frames );
    end

    % generates table of intervals from the intervallist entries
    function makeTab()
        
        tablist = struct2table(intervallist,'AsArray',true);    % convert structure to table, so that certain fields can be safely removed from the displayed table
        tablist.pattern = [];                                   % remove the pattern images
        tablist.contrast = [];                                  % remove contrast string
        tablist.reference = [];                                 % remove reference frame
        inArray = table2array((tablist));                       % convert table to array of doubles, so that the fields are separated into unity width columns
        inArray = round(inArray);                               % round, just to make things look nicer and optimize space
        
        removes = num2cell(false(numel(intervallist),1));       % column of selectable fields to allow removals; cell array
        inData = num2cell(inArray);                             % convert the numeric inputs into cell array (that's what uitable wants)
        inData(:,size(inArray,2)+1) = removes;                  % combine the cell arrays and choke the shrew
        
        htab = uitable('Parent', hlistinterval,'Data', inData, 'ColumnName', colnames, 'ColumnFormat',...
               colformat, 'ColumnEditable',[false false false false false false false false true],...
               'RowName',[], 'Units','normalized','Position',[0,0,0.9,1],...
               'ColumnWidth',{52},'CellEditCallback',@rmtabledint_callback);
    end

    % fits data with one-parametric exponentiel
    function [ est, FitCurve ] = expfit( int, frc, varargin )
            
            inp = inputParser();
            defaultRate = 1;
            
            addRequired(inp, 'int');
            addRequired(inp, 'frc');
            addParameter(inp, 'framerate', defaultRate, @isnumeric);
            
            inp.parse(int, frc, varargin{:});
            
            int = inp.Results.int;
            frc = inp.Results.frc;
            rate = inp.Results.framerate;
            % ===============================
        
            DF = frc(end) - frc(1);     % change in force
            int = (int - int(1))/rate;         % start time at 0
            
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
        exportfile = fullfile(dir,filename);
    end

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

end