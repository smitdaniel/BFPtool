%% This class is just a small wrapper for video files
%   It allows to use the same access funtion for video objects working 
%   with Tiff format (libTiff) and other video formats (videoReader)
%   *IN (constructor):*
%   * videopath   : constructor takes the full path to the videofile
%   
%   *DETAIL:*
%   The wrapper determines the type of the file, and populates the
%   information about the video in the 'Video information' panel in the
%   BFPGUI. It provides (and calculates) frame-by-frame contrast on demand,
%   both SD2 and rSD2, if prompts the user to input framerate for the TIFF
%   videos, and verifies compatibility of video files during session import
%   (even if file name is different).
%   ================================================================

classdef vidWrap < handle

    %% calss properties; containing information about the video
    properties
        
        videopath;  % gives path to the videofile
        istiff;     % determines the type of the video connected to the object
        vidObj;     % video object
        
        Name     = [];  % filename
        Format   = [];  % video file format
        Width    = 0;   % width of frame in pix
        Height   = 0;   % height of frame in pix
        Duration = 0;   % length in seconds
        Framerate = 0;  % frames per second
        Frames   = 0;   % number of frames in the video

        CurrentFrame = 0;   % currently open frame
        
        % supplementary data
        Contrast = [];  % contrast as 2D standard deviation of frame SD2
        GrayLvl = [];   % contrast as a mean intensity level
        LocContrast = [];   % local contrast; rolling variance of SD2 cont.
        
        % contrast calculation parameters
        rollVarWidth = 40;  % width of rolling variance of contrast (in frames)
        
    end

    %% class methods
    % TODO: implement a method to let users change framerate later
    methods
       
        %% constructor, builds appropriate video reader object and wraps it
        function obj = vidWrap( videopath )
            
            % verify the file exists; %TODO: replace error with an
            % informative return information
            if exist(videopath, 'file');
                obj.videopath = videopath;
            else
                error(strcat(videopath,' is not a valid path'));
            end

            % analyze file name
            [~, name, ext ] = fileparts(videopath);
            
            % check if the file if TIFF
            if strcmp(ext,'.tif') || strcmp(ext,'.tiff');
                obj.istiff = true;
                obj.vidObj = Tiff(obj.videopath,'r');   % open tiff file for reading;
                
                obj.Name   = name;
                obj.Format = strcat('Tiff', num2str(obj.vidObj.getTag('BitsPerSample')),'bits');
                obj.Width  = obj.vidObj.getTag('ImageWidth');
                obj.Height = obj.vidObj.getTag('ImageLength');
                frames = regexp(obj.vidObj.getTag('ImageDescription'),'\d*','match');
                if (numel(frames) == 5 || numel(frames) == 6)
                    if isempty(frames{6}); frames{6}=0; end;    % in case FPS is interger
                    obj.Frames = str2double(frames{3});
                    obj.Framerate = round(str2double(strcat(frames{5},'.',frames{6})));
                    obj.Duration = obj.Frames / obj.Framerate;
                else    
                    hdb = obj.getFramerate();
                    uiwait(hdb);
                end
                
                obj.vidObj.setDirectory(1);
                obj.CurrentFrame = 1;
                
                
            else    % if file is not TIFF
                obj.istiff = false;
                obj.vidObj = VideoReader(obj.videopath);
                
                obj.Name = name;
                obj.Format = obj.vidObj.VideoFormat;
                obj.Width  = obj.vidObj.Width;
                obj.Height = obj.vidObj.Height;
                obj.Duration = obj.vidObj.Duration;
                obj.Framerate = obj.vidObj.FrameRate;
                obj.Frames = obj.Duration * obj.Framerate;
                obj.vidObj.CurrentTime = 0;
                obj.CurrentFrame = 1;
            end
        end
        
        %% Frame reader
        % reads and returns next available frame in the video;
        % if index is provided, returns the frame of the given index
        function [frame] = readFrame(obj,varargin)
            
            inp = inputParser();
            defaultIndex = 0;
            
            addOptional(inp,'index',defaultIndex, @(x) ( (x > 0 && x <= obj.Frames) && isnumeric(x) ));
            
            parse(inp, varargin{:});
            
            index = round(inp.Results.index);   % make sure it is integer
            % ========================
            
            frame = struct( 'cdata', zeros(obj.Height, obj.Width, 'uint16'), 'colormap', []);
            
            % separate reading method for tiff and non-tiff
            if obj.istiff
                if index ~= 0;
                    obj.vidObj.setDirectory(index);
                    frame.cdata = obj.setGray(obj.vidObj.read());
                    obj.CurrentFrame = index;
                else
                    obj.vidObj.setDirectory( min(obj.CurrentFrame+1, obj.Frames) ); % read next
                    frame.cdata = obj.setGray(obj.vidObj.read());
                    obj.CurrentFrame = obj.CurrentFrame + 1;
                end
            else
                if index ~= 0;
                    obj.vidObj.CurrentTime = (index-1)/obj.Framerate;       % get time before the indexed frame
                    frame.cdata = obj.setGray(obj.vidObj.readFrame());      % read next frame
                    obj.CurrentFrame = round(obj.vidObj.CurrentTime * obj.Framerate);
                else
                    if obj.vidObj.hasFrame;
                        frame.cdata = obj.setGray(obj.vidObj.readFrame());
                        obj.CurrentFrame = obj.CurrentFrame + 1;
                    end
                end
            end
        end
        
        %% Contrast calculating method
        % Procedure verifies, if the contrast exists for all frames of video,
        % and whether is unbroken (i.e. nonzero) in the requested interval.
        % IN: ffrm-lfrm : first frame to last frame requested
        %     type      : return (in var 'contrast') local contrast variance or
        %                 SD2 value for each frame
        %     rVarWW    : window width for local contrast variance; if this
        %               changes, the rSD2 is recalculated on the function call
        % OUT: contrast : metric (1=SD2, 2=rSD2)
        %      meanGray : mean grayscale value of frames
        % DETAIL: Recalculates all frames if conditions are not met and returns
        % the FULL array 'contrast', not just the requested subinterval.
        % Returned array is truncated ONLY if the process is cancelled by
        % the user. This could be improved.
        function [ contrast, meanGray ] = getContrast(obj, ffrm, lfrm, varargin)
            
            persistent inp;
            
            if isempty(inp)
                inp = inputParser;
                defaultType     = 1;    % contrast SD2 code
                defaultrVarWW   = obj.rollVarWidth; % default window width rSD2

                inp.addRequired('obj');
                inp.addRequired('ffrm');    % initial requested frm
                inp.addRequired('lfrm');    % final requested frm
                inp.addOptional('type', defaultType, @(x) (isfloat(x) && (x==1||x==2)) );       % type of contrast metric; 1 or 2
                inp.addOptional('rVarWW', defaultrVarWW, @(x) (isfloat(x) && x>0) );   % (positive) width of the rSD2 window
            end
                
            inp.parse(obj, ffrm, lfrm ,varargin{:});

            obj = inp.Results.obj;
            ffrm = round(inp.Results.ffrm);
            lfrm = round(inp.Results.lfrm);
            type = inp.Results.type;
            rVarWW = round(inp.Results.rVarWW);
            % ===========================================================
            
            if obj.rollVarWidth ~= rVarWW   % update rolling variance window width if needed
                obj.rollVarWidth = rVarWW;
                redorSD = true;
            else
                redorSD = false;
            end
            % check if the requested interval was analysed (ffrm:lfrm),
            % redo analysis, if it wastn't, return current values otherwise
            % (this is usually for plotting function call)
            if (isempty(obj.Contrast) || numel(obj.Contrast) < obj.Frames || ...
               any(find(obj.Contrast(ffrm:lfrm)==0))) % the last option suggests failed previos run (i.e. contrast should never be zero; only for empty frame)                
                oldFrame = obj.CurrentFrame;
                % generate customized message for contrast calculation
                if isempty(obj.Contrast);
                    str= 'No previous contrast calculation data were found.';
                elseif numel(obj.Contrast) < obj.Frames
                    str= ['Previous contrast calculation data are corrupt.',...
                        'The data do not cover the full length of the video.',...
                        'The previous calculation was probably cancelled.'];
                elseif any(find(obj.Contrast(ffrm:lfrm)==0))
                    badnum = numel(find(obj.Contrast(ffrm:lfrm)==0));
                    str= ['Contrast calculation data of the requested interval are corrupt.',' ',...
                        num2str(badnum), ' ', 'frames have standard deviation SD2=0.',...
                        'Frames might be possibly empty or damaged.'];
                end
                obj.Contrast = zeros(obj.Frames,1,'double');
                obj.GrayLvl  = zeros(obj.Frames,1,'double');
                warning(strjoin({'Contrast will be calculated for the full video.',...
                    'Contrast data were initially requested for the interval',strcat('[',num2str(ffrm),':', num2str(lfrm),']'),...
                    str}));

                disp('Calculating the contrast for each frame of the film.');
                
                % calculation loop + progress bar
                wbmsg = strjoin({'Calculating contrast of video of', num2str(obj.Frames),'frames'});
                hwaitbar = waitbar(0,wbmsg,'Name','Contrast calculation', 'CreateCancelBtn', ...
                    {@cancelwb_callback});
                killwb = false;
                for frm=1:obj.Frames;
                    if killwb; break; end;                    
                    thisFrame = obj.readFrame(frm);
                    doubleFrame = double(thisFrame.cdata);
                    obj.Contrast(frm) = std2(doubleFrame);
                    obj.GrayLvl(frm) = mean2(doubleFrame);
                    if(mod(frm,100)==0); 
                        disp(strcat('Frames processed:', num2str(frm),'/',num2str(obj.Frames))); 
                        waitbar(frm/obj.Frames,hwaitbar);
                    end;
                end

                % normalize; values for contrast and mean-gray are only
                % positive; if they're 0, report suspicion event
                maxContrast = max(obj.Contrast);
                maxGrayLvl  = max(obj.GrayLvl);
                
                obj.getLocalContrast();
                maxLocContrast = max(obj.LocContrast);
                
                if maxContrast ~= 0
                    obj.Contrast = obj.Contrast/maxContrast;
                else
                    warning('The values of contrast measure are suspicious (max=0). Please double check your video.');
                end;
                
                if maxGrayLvl ~= 0
                    obj.GrayLvl  = obj.GrayLvl/maxGrayLvl;
                else
                    warning('The values of mean gray level are suspicions (max=0). Please double check your video.');
                end

                if maxLocContrast ~= 0
                    obj.LocContrast = obj.LocContrast/maxLocContrast;
                else
                    warning('The values of local (rolling) contrast are suspicions (max=0). Please double check your video.');
                end
                obj.readFrame(oldFrame);    % reset the original image
            elseif redorSD      % recalculate local contrast SD, if window width was changed
                obj.getLocalContrast();
                maxLocContrast = max(obj.LocContrast);
                if maxLocContrast ~= 0
                    obj.LocContrast = obj.LocContrast/maxLocContrast;
                else
                    warning('The values of local (rolling) contrast are suspicions (max=0). Please double check your video.');
                end
            end;
            
            % select type of contrast to return
            if type==1
                contrast = obj.Contrast;
            elseif type==2
                contrast = obj.LocContrast;
            end;
            
            meanGray = obj.GrayLvl;
            if exist('hwaitbar','var'); delete(hwaitbar); end;

            % cancel function for the contrast-calculation wait bar
            function cancelwb_callback(~,~)
                killwb = true;
                delete(hwaitbar);
                obj.Contrast(frm+1:end) = [];
                obj.GrayLvl(frm+1:end)  = [];
                disp(strjoin({'Calculation interrupted by user. Currently processed',...
                    num2str(frm), 'frames. The data will remain accessible, but will be recalculated on the next request.'}));
            end
            
        end
        
        %% Method that calculates local contrast from SD2 contrast data
        % calculate rolling variance of the constrast measure SD2
        % TODO: this method should be private, as it uses data first
        % calculated by the getContrast method
        function [ ] = getLocalContrast(obj)
            ww = 2*round(obj.rollVarWidth/2);   % window width, even
            frms = numel(obj.Contrast);         % number of frames w/ SD2
            
            rMean = mean(obj.Contrast(1:ww));   % initial mean and variance
            rVar  = var(obj.Contrast(1:ww));
            obj.LocContrast(1:ww/2) = sqrt(rVar);
            
            for ind = 1:frms-ww
                oMean = rMean;  % save old rolling mean
                rMean = rMean - (obj.Contrast(ind) - obj.Contrast(ind+ww))/ww;    % update the mean
                rVar  = rVar - (obj.Contrast(ind)-obj.Contrast(ind+ww))*...
                        (obj.Contrast(ind+ww)-rMean+obj.Contrast(ind)-oMean)/(ww-1);    % update the variance
                obj.LocContrast(ww/2+ind) = sqrt(rVar);
            end
            
            obj.LocContrast(frms-ww/2+1:frms) = obj.LocContrast(frms-ww/2);  % pad the remaining arrayfields
           
        end
        
        %% Returns contrast for the requested frame
        % return value of contrast at particular frame
        function [contrastfrm] = getContrastByFrame(obj,frm,type)
            if isempty(obj.Contrast); obj.getContrast; end;     % if contrast no calculated yet
            if type==1
                contrastfrm = obj.Contrast(frm);
            elseif type==2
                contrastfrm = obj.LocContrast(frm);
            end
        end
            
        %% Convert the frame to gray scale
        % verify and convert to gray; 
        function [cdata] = setGray(~,cdata)
            if (size(cdata,3) ~= 1); cdata = rgb2gray(cdata); end
        end
        
        %% Set the frame rate of the TIFF video
        % querry user to provide a framerate for TIFF file
        function db = getFramerate(obj)
            inputype = 1;
            inputval = -1;
            obj.vidObj.setDirectory(1);
            while(~obj.vidObj.lastDirectory)    % read until last dir.
                obj.vidObj.nextDirectory;
            end
            obj.Frames = obj.vidObj.currentDirectory;   % set # of frames
            frmval = obj.Frames;
            boxstr = '<input value>';
            frmstr = num2str(frmval);
            db = dialog('Units','pixels','Position',[0 0 640 480], 'Name',...
                'No timestamps in TIFF file', 'WindowStyle', 'modal', 'CloseRequestFcn',@closedb_callback,...
                'Resize','off', 'Visible','off');
            movegui(db,'center');
            db.Visible='on';
            txt = uicontrol('Parent', db, 'Style', 'text', 'Units', 'normalized',...
                'Position', [0.1 0.6 0.8 0.3], 'String', strjoin({'The TIFF file imported does not',...
                'contain information about the time length of the video or its framerate. Please provide,'...
                'the information below. If You cannot acquire such information, please make a calibration',...
                'of You own choice. You can also limit the number of frames to be read by the application.'}),...
                'HorizontalAlignment','left');
            bg = uibuttongroup('Parent', db, 'Units', 'normalized', 'Position', [0.1 0.3 0.8 0.2],...
                'SelectionChangedFcn', {@rb_callback});
            rFR= uicontrol('Parent',bg, 'Style', 'radiobutton', 'String', 'Framerate [FPS]',...
                'Units','normalized', 'Position', [0.1 0.5 0.4 0.5], 'Value', 1);
            rTD= uicontrol('Parent',bg, 'Style', 'radiobutton', 'String', 'Time duration [s]',...
                'Units', 'normalized', 'Position', [0.1 0 0.4 0.5], 'Value', 0);
            bg.SelectedObject = rFR;
            sharebox = uicontrol('Parent',bg,'Style','edit','String',boxstr,...
                'Units','normalized','Position', [0.5 0.5 0.3 0.5],'Callback',{@read_callback,boxstr});
            
            inputxt = uicontrol('Parent',db,'Style','text','Units','normalized',...
                'Position', [0 0.1 0.3 0.1], 'String', strcat('Frames (max.',num2str(frmstr),'):'));
            inputbox = uicontrol('Parent',db,'Style','edit','String',frmstr,'Tag','frm',...
                'Units','normalized','Position', [0.3 0.1 0.3 0.2],'Callback',{@read_callback,frmstr});
            sendbtn = uicontrol('Parent',db,'Style','pushbutton','String','Send','Enable','off',...
                'Units','normalized','Position', [0.6 0.1 0.3 0.2], 'Callback',  @send_callback);
            set([txt,bg,rFR,rTD,inputxt,inputbox,sendbtn], 'FontUnits', 'pixels','FontSize',14);
            
            % radio buttons to switch between framerate and duration
            function rb_callback(~,data)
                if data.NewValue == rFR
                    inputype= 1;
                    sharebox.Position = [0.5 0.5 0.3 0.5];
                else
                    inputype= 2;
                    sharebox.Position = [0.5 0 0.3 0.5];
                end
            end
            
            % verify the value
            function read_callback(src,~,oldval)
                val = str2double(src.String);
                if ~isnan(val) && (val>0)
                    if strcmp(src.Tag,'frm')
                        val = round(val);
                        if val > obj.Frames
                            src.String=oldval;                            
                            warndlg(strcat('Input must be a positive number of type double, <',num2str(obj.Frames+1)),...
                                'Incorrect input', 'replace');
                            return;
                        end
                        frmval = val;   % # of frames
                    else
                        inputval = val; % duration or fps
                    end
                    src.Callback = {@read_callback,num2str(val)};
                    src.String = val; % modifie to interger, if frame #
                    if (inputval ~= -1 && frmval ~= -1)
                        sendbtn.Enable = 'on';  % if both values provided, enable send btn
                    end
                else
                    src.String = oldval;
                    warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
                    return;
                end
            end
            
            % accept function
            function send_callback(~,~)
                if inputype == 1    % case of framerate
                    if ~isnan(inputval) && (inputval > 0)
                        obj.Framerate = inputval;
                        obj.Frames = frmval;
                        obj.Duration = obj.Frames/obj.Framerate; % duration in seconds
                    else
                        warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
                        sharebox.String = '<input value>';
                        inputval = -1;
                        sendbtn.Enable = 'off';
                        return;
                    end
                else
                    if ~isnan(inputval) && (inputval > 0)
                        obj.Duration = inputval;
                        obj.Frames = frmval;
                        obj.Framerate = obj.Frames/obj.Duration; % framerate in FPS
                    else
                        warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
                        sharebox.String = '<input value>';
                        inputval = -1;
                        sendbtn.Enable = 'off';
                        return;
                    end
                end
                db.delete;  % delete the dialog
            end
            
            % attempt to close the dialog prematurely
            function closedb_callback(~,~)
                choice = questdlg(strcat('No input was passed.',...
                    'Failsafe values will be used -- framerate of 1 FPS.',...
                    'Do You want to close this window anyway?'),'No framerate information','Yes','No','No');
                switch choice
                    case 'Yes'
                        obj.Framerate = 1;
                        obj.Duration = obj.Frames/obj.Framerate;    % set time in s
                        db.delete;  % delete dialog box
                    case 'No'
                        return;     % keep open and return
                end
            end
            
        end
        
        %% Verify the object video and video of another object match
        % compare the properties of videos, to see if they are the same
        function match = matchVideos(obj, vidObjToMatch)
            match = struct('format',false,'width',false,'height',false,...
                'frames',false,'result',false); % initial match structure
            
            match.format= strcmp(obj.Format, vidObjToMatch.Format);
            match.width =(obj.Width  == vidObjToMatch.Width);
            match.height=(obj.Height == vidObjToMatch.Height);
            match.frames=(obj.Frames == vidObjToMatch.Frames);
            match.result= (match.format && match.width && match.height && match.frames);   % if any is false, result is false
        end
    end
end