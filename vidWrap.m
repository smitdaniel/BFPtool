%   This class is just a small wrapper to allow for using the same
%   getters and setters for video objects working with Tiff format
%   (libTiff) and other video formats (videoReader)
%   IN:
%   videopath   : constructor takes the full path to the videofile
%   DETAIL :
%   The wrapper determines the type of the file, and populates the
%   information about the video in the 'Video information' panel in the
%   BFPGUI. It provides (and calculates) frame-by-frame contrast on demand.
%   ================================================================

classdef vidWrap < handle

    properties
        
        videopath;  % gives path to the videofile
        istiff;     % determines the type of the video connected to the object
        vidObj;     % video object
        
        Name     = [];
        Format   = [];
        Width    = 0;
        Height   = 0;
        Duration = 0;
        Framerate = 0;
        Frames   = 0;       % number of frames in the video

        CurrentFrame = 0;
        
        % supplementary data
        Contrast = [];  % contrast as standard deviation SD2
        GrayLvl = [];   % contrast as a mean intensity level
        LocContrast = [];   % local contrast; rolling variance of SD2
        
        % contrast calculation parameters
        rollVarWidth = 40;  % width of rolling variance of contrast
        
    end

    methods
       
        % constructor, builds the video reader object and wraps it
        function obj = vidWrap( videopath )
            
            if exist(videopath, 'file');
                obj.videopath = videopath;
            else
                error(strcat(videopath,' is not a valid path'));
            end

            [~, name, ext ] = fileparts(videopath);
            
            if strcmp(ext,'.tif') || strcmp(ext,'.tiff');
                obj.istiff = true;
                obj.vidObj = Tiff(obj.videopath,'r');   % open tiff file for reading;
                
                obj.Name   = name;
                obj.Format = strcat('Tiff', num2str(obj.vidObj.getTag('BitsPerSample')),'bits');
                obj.Width  = obj.vidObj.getTag('ImageWidth');
                obj.Height = obj.vidObj.getTag('ImageLength');
                frames = regexp(obj.vidObj.getTag('ImageDescription'),'\d*','match');
                obj.Frames = str2double(frames{3});
                obj.vidObj.setDirectory(1);
                obj.CurrentFrame = 1;
                
                % default values for now
                obj.Duration  = obj.Frames;
                obj.Framerate = 1;
                
            else
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
            
            if obj.istiff
                if index ~= 0;
                    obj.vidObj.setDirectory(index);
                    frame.cdata = obj.vidObj.read();
                    obj.CurrentFrame = index;
                else
                    obj.vidObj.setDirectory( min(obj.CurrentFrame+1, obj.Frames) ); % read next
                    frame.cdata = obj.vidObj.read();
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
        
        % Procedure verifies, if the contrast exists for all frames of video,
        % and if is unbroken (i.e. nonzero) in the requested interval. 
        % Recalculates all frames if conditions are not met and returns
        % the FULL array 'contrast', not just the requested subinterval.
        % Returned array is truncated ONLY if the process is cancelled by
        % the user.
        function [ contrast, meanGray ] = getContrast(obj, ffrm, lfrm)
            % check if the requested interval was analysed (ffrm:lfrm),
            % redo analysis, if it wastn't, return current values otherwise
            % (this is usually for plotting function call)
            if (isempty(obj.Contrast) || numel(obj.Contrast) < obj.Frames || ...
               any(find(obj.Contrast(ffrm:lfrm)==0))) % the last option suggests failed previos run (i.e. contrast should never be zero)                
                oldFrame = obj.CurrentFrame;
                obj.Contrast = zeros(obj.Frames,1,'double');
                obj.GrayLvl  = zeros(obj.Frames,1,'double');
                warning(strjoin({'Contrast for the requested interval',strcat('[',...
                    num2str(ffrm),':', num2str(lfrm),']'),'was either not calculated before, not',...
                    'finished, or the results are malformed. Contrast will be recalculated',...
                    'for the whole video.'}));

                disp('Calculating the contrast for each frame of the film.');
                
                wbmsg = strjoin({'Calculating contrast of video of', num2str(obj.Frames),'frames'});
                hwaitbar = waitbar(0,wbmsg,'Name','Contrast calculation', 'CreateCancelBtn', ...
                    {@cancelwb_callback});
                killwb = false;
                for frm=1:obj.Frames;
                    if killwb; break; end;
                    waitbar(frm/obj.Frames,hwaitbar);
                    thisFrame = obj.readFrame(frm);
                    doubleFrame = double(thisFrame.cdata);
                    obj.Contrast(frm) = std2(doubleFrame);
                    obj.GrayLvl(frm) = mean2(doubleFrame);
                    if(mod(frm,100)==0); disp(strcat('Frames processed:', num2str(frm),'/',num2str(obj.Frames))); end;
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
            end;
            
            %contrast = obj.Contrast;
            contrast = obj.Contrast;
            meanGray = obj.GrayLvl;
            if exist('hwaitbar','var');delete(hwaitbar); end;

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
        
        % return value of contrast at particular frame
        function [contrastfrm] = getContrastByFrame(obj,frm)
            if isempty(obj.Contrast); obj.getContrast; end;     % if contrast no calculated yet
            contrastfrm = obj.Contrast(frm);
        end
            
        
        % verify and convert to gray; 
        function [cdata] = setGray(~,cdata)
            if (size(cdata,3) ~= 1); cdata = rgb2gray(cdata); end
        end
        
        % querry user to provide a framerate for TIFF file
        function db = getFramerate(obj)
            inputype = 1;
            inputval = -1;
            boxstr = 'input value';
            db = dialog('Units','normalized','Position',[0.25 0.25 0.5 0.5], 'Name',...
                'No timestamps in TIFF file', 'WindowStyle', 'modal', 'CloseRequestFcn',@closedb_callback,...
                'Resize','on');
            txt = uicontrol('Parent', db, 'Style', 'text', 'Units', 'normalized',...
                'Position', [0.1 0.6 0.8 0.4], 'String', strjoin({'The TIFF file imported does not',...
                'contain information about the time length of the video or its framerate. Please provide,'...
                'the information below. If You cannot acquire such information, please make a calibration',...
                'of You own choice.'}),'HorizontalAlignment','left');
            bg = uibuttongroup('Parent', db, 'Units', 'normalized', 'Position', [0.1 0.3 0.8 0.3],...
                'SelectionChangedFcn', {@rb_callback});
            rFR= uicontrol('Parent',bg, 'Style', 'radiobutton', 'String', 'Framerate [FPS]',...
                'Units','normalized', 'Position', [0.1 0.5 0.8 0.5], 'Value', 1);
            rTD= uicontrol('Parent',bg, 'Style', 'radiobutton', 'String', 'Time duration [s]',...
                'Units', 'normalized', 'Position', [0.1 0 0.8 0.5], 'Value', 0);
            bg.SelectedObject = rFR;
            inputxt = uicontrol('Parent',db,'Style','text','Units','normalized',...
                'Position', [0 0.1 0.3 0.2], 'String', 'Framerate:');
            inputbox = uicontrol('Parent',db,'Style','edit','String',boxstr,...
                'Units','normalized','Position', [0.3 0.1 0.3 0.2],'Callback',{@read_callback,boxstr});
            sendbtn = uicontrol('Parent',db,'Style','pushbutton','String','Send','Enable','off',...
                'Units','normalized','Position', [0.6 0.1 0.3 0.2], 'Callback',  @send_callback);
            set([txt,bg,rFR,rTD,inputxt,inputbox,sendbtn], 'FontUnits', 'normalized');
            
            % radio buttons to switch between framerate and duration
            function rb_callback(~,data)
                if data.NewValue == rFR
                    inputxt.String = 'Framerate [FPS]:';
                    inputype= 1;
                    sendbtn.Enable = 'on';
                else
                    inputxt.String = 'Duration [s]:';
                    inputype= 2;
                    sendbtn.Enable = 'on';
                end
            end
            
            % verify the value
            function read_callback(src,~,oldval)
                val = str2double(src.String);
                if ~isnan(val) && (val>0)
                    inputval = val;
                    src.Callback = {@read_callback,num2str(val)};
                    sendbtn.Enable = 'on';
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
                        obj.Duration = obj.Frames/obj.Framerate; % duration in seconds
                    else
                        warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
                        return;
                    end
                else
                    if ~isnan(inputval) && (inputval > 0)
                        obj.Duration = inputval;
                        obj.Framerate = obj.Frames/obj.Duration; % framerate in FPS
                    else
                        warndlg('Input must be a positive number of type double','Incorrect input', 'replace');
                        return;
                    end
                end
                db.delete;  % delete the dialog
            end
            
            % attempt to close the dialog prematurely
            function closedb_callback(~,~)
                choice = questdlg(strcat('No input was passed. Failsafe values will be used -- framerate of 1 FPS.',...
                    'Do You want to close this window anyway?'),'No framerate information','Yes','No','No');
                switch choice
                    case 'Yes'
                        db.delete;  % delete dialog box
                    case 'No'
                        return;     % keep open and return
                end
            end
            
        end
        
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