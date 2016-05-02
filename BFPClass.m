    %BFP Holds data and methods for BFP experiment analysis
    %   This class saves settings and results of the analysis of BFP
    %   experiments. It contains methods to operate in discontiguous
    %   interval landscape, sub-call TrackBead and TrackPipette methods
    %   with appropriate settings, generate graphs (taking a handle) of
    %   data, calculate stiffness and corresponding time evolution of
    %   force, import data and generate fidelity report
    %   ===============================================================

classdef BFPClass < handle
    
    properties
        
        % computational variables
        name;           % name of the experiment = name of the video file
        vidObj;         % video object handle
        beadPositions;  % positions of the bead centre during the experiment
        pipPositions;   % positions of the pipette tip during the experiment
        force;          % force exerted through the BFP
        tracked;        % sets true when tracking is finished
        trackedFrames;  % number of frames processed by the tracking method
        minFrame;       % minimal tracked frame of video
        maxFrame;       % maximal tracked frame of video
        toBeTracked;    % number of frames to be tracked, based on imported intervallist

        % list of intervals in the video to track; contains all the
        % necessary information: the patterns to track, time intervals,
        % initial points of search, anchor on the pattern, zero force
        % point
        intervallist;
        
        % experimental parameters
        Rg; % radius of RBC
        Rc; % radius of RBC-SB contact 
        Rp; % radius of the pipette
        P;  % pressure in the pipette
        P2M; % scale of the video; pixels to microns (for ENS exp. generally 0.1024 um = 1 px)
        k;  % stiffness of the BFP
        Dk; % stiffness error
        
        % bead tracking settings
        radius;
        buffer;
        sensitivity;
        edge;
        metric;
        killTrack;  % trigger to cancel tracking
        
        % pipette tracking settings
        correlation;
        contrast;
        pipbuffer;
        
        % errors of measurement (should be editable)
        DP = 10;    % implicit error of pressure measurement, 10 Pa
        DR = 0.1;   % implicit error of radius measurement, 0.1 micron
        linearLimit = 0.5;  % limit on extension for good linear approximation is ~500 nm
        
    end

    % rather technical parameters; might be fine-tuned across platforms
    properties (Constant)
       labelfontsize = 0.05;    % font size for legend, axes etc. 
       reportfontsize = 0.04;   % font size for a report pop-up window 
    end
    
    methods
        % constructor
        function obj = BFPClass(varargin)   % in order: name, vidObj, intlist
            
            obj.killTrack = false;  % initially, do tracking
            
            if nargin == 0  % default constructor
                obj.name = 'default';
                obj.tracked = false;
                obj.trackedFrames = 0;    
                obj.toBeTracked = 0;
            else
                intlist = varargin{3};
            
                obj.tracked = false;                % no tracking done when object is created
                obj.trackedFrames = 0;
                obj.toBeTracked = 0;
                obj.name = varargin{1};             % set calc obj name
                obj.vidObj = varargin{2};           % set video object handle (access the video)
                obj.maxFrame = 1;
                obj.minFrame = obj.vidObj.Frames;   % number of frames in the video
                fields = fieldnames(intlist(1));
                inters = numel(intlist);
                for int=1:inters                    % copy the list of intervals in the video to analyze
                    for nam=1:numel(fields)
                       obj.intervallist(int).(fields{nam}) = intlist(int).(fields{nam});
                    end
                    if (obj.intervallist(int).frames(1)~=obj.intervallist(int).frames(2))   % ignore one frame intervals
                        obj.minFrame = min(obj.intervallist(int).frames(1), obj.minFrame);
                    end
                    obj.maxFrame = max(obj.intervallist(int).frames(2), obj.maxFrame);
                    obj.toBeTracked = obj.toBeTracked + 1 + ...     % calculate the number of frames in list to process
                                      obj.intervallist(int).frames(2) - obj.intervallist(int).frames(1);
                end
                if obj.minFrame > obj.maxFrame; obj.minFrame = obj.maxFrame; end;   % if only single frame intervals are present (which is unlikely)
            end
        end
        
        % set up experimental parameters;
        function getParameters(obj,Rg,Rc,Rp,P)
            obj.Rg = Rg;
            obj.Rc = Rc;
            obj.Rp = Rp;
            obj.P = P;
            obj.getStiffness(); % calculate the RBC stiffness (w/ uncert.)
        end
        
        % set up settings for bead tracking
        function getBeadParameters(obj,radius,buffer,sensitivity,edge,metric,P2M)
            obj.radius = radius;
            obj.buffer = buffer;
            obj.sensitivity = sensitivity;
            obj.edge   = edge;
            obj.metric = metric;
            obj.P2M = P2M;
        end
        
        % set up settings for pipette tracking
        function getPipParameters(obj,correlation,contrast,buffer)
            obj.correlation = correlation;
            obj.contrast    = contrast;
            obj.pipbuffer   = buffer;
        end
        
        % triggers tracking procedures; takes axes handle to plot results
        function Track(obj, hplot)
            
            obj.killTrack = false;  % set tracking to continue
            htrackbar = waitbar(0,'Tracking is about to start','Name','Tracking', 'CreateCancelBtn', ...
                    {@canceltb_callback},...%'Units', 'normalized', ...
                    'Resize','on','Visible','on');  % create waitbar figure and pass it on tracking methods
%             tbax = findobj(htrackbar,'type','axes');
%             tbax.Units = 'normalized';
%             tbax.Title.FontUnits = 'normalized';
%             htrackbar.Visible = 'on';
            htrackbar.UserData.intmsg = 'Tracking is about to start';   % waitbar initial message
            cla(hplot,'reset');
            for int = 1:numel(obj.intervallist)
                htrackbar.UserData.intmsg = strjoin({'Tracking interval',num2str(int),'of',num2str(numel(obj.intervallist))});
                waitbar(0,htrackbar,htrackbar.UserData.intmsg);
                if obj.killTrack; break; end;   % break the tracking if cancelled
                [obj.pipPositions(int).coor, obj.pipPositions(int).metric, obj.pipPositions(int).bads] = ...
                                            TrackPipette( obj.vidObj, obj.intervallist(int).pattern,...
                                            obj.intervallist(int).patcoor,obj.intervallist(int).frames,...
                                            'robustness',obj.correlation, 'quality', obj.contrast,...
                                            'buffer', obj.pipbuffer, 'waitbar', htrackbar);
                [obj.beadPositions(int).coor,obj.beadPositions(int).rad,obj.beadPositions(int).metric,...
                                            obj.beadPositions(int).bads]  = ...
                                            TrackBead( obj.vidObj, obj.intervallist(int).contrast,...
                                            obj.intervallist(int).beadcoor, obj.intervallist(int).frames,...
                                            'radius', obj.radius, 'buffer', obj.buffer, 'sensitivity', obj.sensitivity,...
                                            'edge', obj.edge, 'robustness', obj.metric, 'quality', obj.contrast,...
                                            'waitbar', htrackbar);
                
                % shift the detected coordinate (upper left corner) to the
                % position of the anchor; change units from px to microns
                obj.pipPositions(int).coor    = obj.pipPositions(int).coor + repmat ([obj.intervallist(int).patsubcoor(2),obj.intervallist(int).patsubcoor(1)], size(obj.pipPositions(int).coor,1),1);                        
                obj.pipPositions(int).coor    = obj.px2um(obj.pipPositions(int).coor);
                obj.beadPositions(int).coor   = obj.px2um(obj.beadPositions(int).coor);
                obj.beadPositions(int).rad    = obj.px2um(obj.beadPositions(int).rad);
                %obj.beadPositions(int).metric = obj.beadPositions(int).metric/(max(obj.beadPositions(int).metric));
                
                
                % modify number of tracked frames
                obj.trackedFrames = obj.trackedFrames + ...
                                   (obj.intervallist(int).frames(2)-obj.intervallist(int).frames(1)+1);
            end
            obj.plotTracks(hplot,obj.minFrame,obj.maxFrame,true,true,'Style','2D');          % plot the tracking data
            obj.tracked = true;             % set 'tracked' flag
            obj.generateReport();
        end
        
        % callback to kill tracking by pressing cancel on wb
        function canceltb_callback(~,~)
            obj.killTrack = true;
            delete(htrackbar);
        end
        
        % plots detected tracks; in 3D, the z-dimension is the time axis
        function [] = plotTracks(obj, hplot, varargin )
            inp = inputParser();
            defaultFirst = 1;
            defaultLast  = obj.intervallist(end).frames(2);
            defaultBead  = true;
            defaultPip   = true;
            defaultStyle = '3D';
            styleList = {'2D','3D','F','M'};    % trajectory, track, force, metric
            
            addRequired(inp,'hplot');   % handle to axes
            addOptional(inp,'fInd',defaultFirst, @(x) (x > 0 && x <= defaultLast && isnumeric(x)));
            addOptional(inp,'lInd',defaultLast, @(x) (x > 0 && isnumeric(x)));
            addOptional(inp,'pip' ,defaultPip,  @islogical);
            addOptional(inp,'bead',defaultBead, @islogical);
            addParameter(inp,'Style',defaultStyle, @(x) any(validatestring(x,styleList)));
            
            parse(inp,hplot,varargin{:});
            hplot = inp.Results.hplot;
            fInd  = inp.Results.fInd;
            lInd  = inp.Results.lInd;
            pip   = inp.Results.pip;
            bead  = inp.Results.bead;
            style = inp.Results.Style;
            % ===========================            
            
            if strcmp(style,'2D') || strcmp(style,'3D')
                if pip && ~bead && numel(obj.pipPositions)==0       % plot only pipette, but no pipette
                    disp('No pipette data');
                    return;
                elseif bead && ~pip && numel(obj.beadPositions)==0  % plot only bead, but no bead
                    disp('No bead data');
                    return;
                end
            elseif strcmp(style,'F') && numel(obj.force)==0         % plot force byt no force
                disp('No force data')
                return;
            elseif strcmp(style,'M')
                if pip && ~bead && numel(obj.pipPositions)==0
                    disp('No pipette data');
                    return;
                elseif bead && ~pip && numel(obj.beadPositions)==0
                    disp('No bead data');
                    return;
                end
            end;
                        
            cla(hplot,'reset');
            set(hplot,'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
            
            for int=1:numel(obj.intervallist)
                hold(hplot,'on');
                if obj.intervallist(int).frames(1) > lInd || obj.intervallist(int).frames(2) < fInd; continue; end;
                
                ffrm = max(fInd,obj.intervallist(int).frames(1));
                lfrm  = min(lInd,obj.intervallist(int).frames(2));
                
                start = ffrm - obj.intervallist(int).frames(1) + 1;
                stop  = lfrm - obj.intervallist(int).frames(1) + 1;
                
                if strcmp(style,'F')
                    plot( hplot, ffrm:lfrm, obj.force(int).values(start:stop),'g','HitTest','off' );
                    lh = legend(hplot,'force');
                    th = title(hplot, 'Force [pN]','Color','green', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                    xlabel(hplot, 'time [frames]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                    ylabel(hplot, 'Force [pN]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                    hold on;
                else
                    if pip && numel(obj.pipPositions) ~= 0;
                        if strcmp(style,'3D')
                            plot3(hplot,obj.pipPositions(int).coor(start:stop,2),...
                            obj.pipPositions(int).coor(start:stop,1),ffrm:lfrm,'b','HitTest','off');
                        elseif strcmp(style,'2D')
                            plot(hplot,obj.pipPositions(int).coor(start:stop,2),...
                            obj.pipPositions(int).coor(start:stop,1),'b','HitTest','off');
                        elseif strcmp(style, 'M')
                            plot( hplot, ffrm:lfrm, obj.pipPositions(int).metric(start:stop), 'b', 'HitTest','off');
                        end
                    end

                    if bead && numel(obj.beadPositions) ~= 0;
                        if strcmp(style,'3D')
                            plot3(hplot,obj.beadPositions(int).coor(start:stop,2),...
                            obj.beadPositions(int).coor(start:stop,1),ffrm:lfrm,'r','HitTest','off');
                        elseif strcmp(style,'2D')
                            plot(hplot,obj.beadPositions(int).coor(start:stop,2),...
                            obj.beadPositions(int).coor(start:stop,1),'r','HitTest','off');
                        elseif strcmp(style, 'M')
                            plot( hplot, ffrm:lfrm, obj.beadPositions(int).metric(start:stop), 'r', 'HitTest','off');
                        end
                    end
                    % plot appropriate legend
                    if pip && bead;
                        lh = legend(hplot, 'pipette', 'bead');
                    elseif pip;
                        lh = legend(hplot, 'pipette');
                    elseif bead
                        lh = legend(hplot, 'bead');
                    end
                end
                lh.Box = 'off';
                lh.FontUnits = 'normalized';                
                switch(style)
                    case '3D'
                        th = title(hplot, {'Tracks in time';'[third coordinate is temporal]'},'Color','blue');
                        xlabel(hplot,'x-coordinate [\mu m]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                        ylabel(hplot,'y-coordinate [\mu m]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                        zlabel(hplot,'time [frames]','FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                    case '2D'
                        th = title(hplot, {'Trajectories';'[set of all spatial points over time]'},'Color','blue');
                        xlabel(hplot,'x-coordinate [\mu m]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                        ylabel(hplot,'y-coordinate [\mu m]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                    case 'M'
                        th = title(hplot, {'Detection metrics';'[robustness of pipette and bead detection]'},'Color','red');
                        xlabel(hplot,'time [frames]', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                        ylabel(hplot,'metric', 'FontUnits','normalized','FontSize',BFPClass.labelfontsize);
                end
                th.FontUnits = 'normalized';
                th.FontSize = BFPClass.labelfontsize;
            end
            
        end
        
        % generates a movie of tracking
        function [] = generateTracks( obj, varargin )
           
            if ~obj.tracked;
                choice = questdlg('The tracking procedure has not been run yet, would You like to run it now?',...
                    'No tracking data to write', 'Track', 'Cancel', 'Track');
                switch choice
                    case 'Track'
                        newfig = figure;
                        newax  = axes('Parent',newfig);
                        obj.Track( newax );
                    case 'Cancel'
                        return
                end;
            end;                
                
            inp = inputParser();
            [defaultVideoPath,~,~] = fileparts(obj.vidObj.videopath);
            defaultName = strcat(obj.name,'Tracks.avi');
            defaultProfile = 'Motion JPEG AVI';
            defaultFramerate = 10;
            defaultSampling = 1;
            
            addParameter(inp,'VideoPath',defaultVideoPath, @(x) exist(x,'dir') );
            addParameter(inp,'Name', defaultName, @ischar);
            addParameter(inp,'Profile', defaultProfile, @ischar);
            addParameter(inp,'Framerate',defaultFramerate, @isnumeric);
            addParameter(inp,'Sampling', defaultSampling, @isnumeric);
            
            parse(inp, varargin{:});
            
            VideoPath   = fullfile(inp.Results.VideoPath,inp.Results.Name);
            Profile     = inp.Results.Profile;
            Framerate   = inp.Results.Framerate;
            Sampling    = inp.Results.Sampling;
            % ==================================
            
            piprad = 5;     % pipette radius 
            totCount = 0;   % total counter of all generated frames
            vidWriteObj = VideoWriter(VideoPath,Profile);  % set up writer object
            vidWriteObj.FrameRate = Framerate;
            vidWriteObj.Quality = 100;          % maximal quality
            open(vidWriteObj);                  % open the file
            hhide = figure('Visible','off');        % start an invisible figure
            haxes = axes('Parent',hhide);
            
            % parse all analyzed frames in intervals
            for int=1:numel(obj.intervallist)
                count = 1;    
                for frm=obj.intervallist(int).frames(1):Sampling:obj.intervallist(int).frames(2)
                    frame = obj.vidObj.readFrame(frm);      % read new frame
                    if(mod(totCount,100)==0); disp(strcat('Frames finished:', num2str(100*round(totCount/obj.trackedFrames,2)),' %')); end;            
                    set(groot,'CurrentFigure',hhide);
                    imagesc(frame.cdata, 'Parent', haxes);
                    colormap(gray);
                    axis(haxes,'image','off');
                    beadCentre = um2px([obj.beadPositions(int).coor(count,2), obj.beadPositions(int).coor(count,1)]); % Matlab coordinate system for displaying (testing)
                    pipCentre  = um2px([obj.pipPositions(int).coor(count,2), obj.pipPositions(int).coor(count,1)]);
                    rad = um2px(obj.beadPositions.rad(count));
                    viscircles(beadCentre,rad, 'EdgeColor','red');
                    viscircles(pipCentre,piprad,'EdgeColor','blue');                    
                    text(20,20,strcat('Frame: ', num2str(count),'/',num2str(obj.trackedFrames)));
                    vidFrame = getframe(haxes);
                    writeVideo(vidWriteObj,vidFrame);
                    count = count + Sampling;
                    totCount = totCount + Sampling;
                end;
            end;
            close(vidWriteObj);
            disp('Frames finished: 100 %');
        end
        
        
        % triggers force calculating procedure
        function [overLimit] = getForce(obj, hplot)
            
            overLimit = false;
            
            if ( ~obj.tracked )
                warndlg('No tracking data. Running tracking methods','Tracking data not available','replace');
                obj.Track(hplot);
            end
            
            refdist = zeros(numel(obj.intervallist),1);   % preallocate array to contain reference distances
            % search reference frames and calculate reference distance for
            % each interval; this will be passed to force calc. procedure
            for int=1:numel(obj.intervallist)
                ind = 0;
                for oint=1:numel(obj.intervallist)
                    % test if reference is in this interval
                    if ( obj.intervallist(int).reference >= obj.intervallist(oint).frames(1)  &&...
                         obj.intervallist(int).reference <= obj.intervallist(oint).frames(2) );
                        ind = oint;  % save interval number
                        coorind = obj.intervallist(int).reference - obj.intervallist(ind).frames(1) + 1;
                        refdist(int) = norm( obj.pipPositions(ind).coor(coorind,:)...
                                            - obj.beadPositions(ind).coor(coorind,:) );
                    end
                end
                if (ind==0);
                    warndlg({strcat('Unstrained distance for interval ',num2str(int), ' refers to the frame ',...
                        num2str(obj.intervallist(int).reference), ' which is not member of any analyzed interval');...
                        'Double check the settings, update the calculation and try again';...
                        'Calculation will be aborted'},'Incorrect reference frame', 'replace');
                    return;
                end
            end
            
            % verify, if number of reference distances matches the number
            % of reference intervals - this error would be very strange
            if (numel(refdist) ~= numel(obj.intervallist))
                warndlg({'Number of detected reference distances does not match the number of analyzed intervals';...
                    'This is very strange, because previous checks should have averted this.';...
                    'The calculation will be aborted. Try again with careful checking.'},...
                    'Mysterious reference distance inequality','replace');
                return;
            end;
            
            cla(hplot,'reset');
            rotate3d(hplot,'off');
            hold(hplot,'on');
            % if all passed, calculate the force
            for int=1:numel(obj.intervallist);
                % verify if the number of parsed frames matches
                if (size(obj.pipPositions(int).coor,1) ~= size(obj.beadPositions(int).coor,1) ||...
                    size(obj.pipPositions(int).coor,1) ~= ...
                        (obj.intervallist(int).frames(2)-obj.intervallist(int).frames(1)+1) )
                    warndl({'The number of tracked frames does not match';...
                        strcat('Pipette: ', num2str(size(obj.pipPositions(int).coor,1)));...
                        strcat('Bead: ',    num2str(size(obj.beadPositions(int).coor,1)));...
                        strcat('Interval: ',num2str(obj.intervallist(int).frames(2)-obj.intervallist(int).frames(1)+1))},...
                        'Unmatched frame count', 'replace');
                    return;
                end   
                
                % get number of frames in the interval and preallocate
                frames = obj.intervallist(int).frames(2)-obj.intervallist(int).frames(1)+1;
                obj.force(int).values = zeros(frames,1);
                
                % calculate force of each frame in the interval
                for pos=1:frames
                    extension = norm(obj.pipPositions(int).coor(pos,:) - obj.beadPositions(int).coor(pos,:)) -...
                                refdist(int);
                    if abs(extension) > obj.linearLimit && overLimit == false;   % found to be over linear limit
                        warndlg(strjoin({'The extension at frame',num2str(obj.intervallist(int).frames(1)+pos),...
                        'is',num2str(round(extension,2)),'microns, and exceeds the limit for linear approximation of force,',...
                        num2str(obj.linearLimit),...
                        'microns. The force would be slightly overestimated, but even at the level of 1 micron,'...
                        'error would be about 20%, depending on the probe stiffness. This warning will not be'...
                        'repeated during this calculation of force.'}),'Force exceeds linear approximation condition',...
                        'replace');
                        overLimit = true;
                    end;
                    obj.force(int).values(pos) = obj.k * extension;
                end
            
                % plot force of just calculated interval
%                 plot( hplot, obj.intervallist(int).frames(1):obj.intervallist(int).frames(2),...
%                       obj.force(int).values,'g','HitTest','off' );
            end
            obj.plotTracks(hplot,obj.minFrame,obj.maxFrame,false,false,'Style','F');
        end
        
        % return force value by frame;  %TODO: ADD INPUT PARSER
        function [value] = getByFrame(obj,frm,type)
            
            givenan = true;     % suppose frame does not belong to any interval, return NaN is such case
            for int = 1:numel(obj.intervallist)
                if ((frm >= obj.intervallist(int).frames(1)) && (frm <= obj.intervallist(int).frames(2)))
                    frcint = int;   % find the interval of the frame
                    givenan = false;
                    break
                end;
            end;
            
            % if frame's out of interval, return NaN
            if givenan
                if strcmp(type,'force')
                    value = nan;
                else
                    value = [nan,nan];
                end
            else    % return the value otherwise
                frmind = frm - obj.intervallist(frcint).frames(1) + 1;  % find local index of the frame
            
                switch type
                    case 'force'
                        value = obj.force(int).values(frmind);
                    case 'pipette'
                        value = [ obj.pipPositions(int).coor(frmind,2),...
                                  obj.pipPositions(int).coor(frmind,1)];
                    case 'bead'
                        value = [ obj.beadPositions(int).coor(frmind,2),...
                                  obj.beadPositions(int).coor(frmind,1)];
                    case 'metric'
                        value = [ obj.beadPositions(int).metric(frmind),...
                                  obj.pipPositions(int).metric(frmind) ];
                end
            end
        end
        
        % imports outer data into GUI; note that data must be formatted in
        % columns; first column is frame number, second column is
        % force/contrast value; in case of coordinates, the first column
        % x-coordinate, third column y-coordinate
        function importData(obj,type,data,varargin)
            
            inp = inputParser();
            defaultRange = [ min(data(:,1)), max(data(:,1)) ];
            expectedTypes = { 'force', 'beadPositions', 'pipPositions' };
            
            inp.addRequired( 'type', @(x) any(validatestring(x,expectedTypes)) );
            inp.addRequired( 'data', @isnumeric );
            inp.addParameter('range', defaultRange, @(x) (isnumeric(x) && numel(x)==2 && x(1) > 0 && x(2) > 0 && x(2) >= x(1)) );
            
            inp.parse(type,data);
            type = inp.Results.type;    % which data are imported/overwritten
            data = inp.Results.data;    % the data to import in form of (numeric) array
            range = inp.Results.range;  % range of frames
            % ============================================================
            
            persistent importedData;    % flag if data's imported or not
            if isempty(importedData); importedData=false; end;
            
            if strcmp(type,'force')
                values = 'values';
            else
                values = 'coor';
            end
            
            continues = false;
            tempIntervals = [];
            intLines = [];
            for line=1:size(data,1);    % read all input lines one by one
                if ( data(line,1) >= range(1) && data(line,1) <= range(2) ) % if frame's within range
                    if ( continues && (data(line,1)-1==data(line-1,1)) ) && line~=size(data,1)
                        continue;
                    elseif ~continues
                        tempIntervals(end+1).frames(1) = data(line,1);
                        intLines(end+1) = line;
                        continues = true;
                    elseif (~( data(line,1)==data(line-1,1) + 1 ) || line==size(data,1) ) && continues 
                        tempIntervals(end).frames(2) = data(line,1);
                        continues = false;
                    end
                end
            end
            
            
            str = strcat('[',num2str(tempIntervals(1).frames(1)),',',...
                             num2str(tempIntervals(1).frames(2)),']');
            for int=2:numel(tempIntervals)
                str = strcat({str; strcat('[',num2str(tempIntervals(int).frames(1)),',',...
                                            num2str(tempIntervals(int).frames(2)),']')});
            end;
            
            choice = questdlg(strjoin({'Following intervals were identified within the data:',...
                str, 'If the division is not as You would expect, please review Your data.'},'\n'),...
                'Interval review','Accept','Cancel','Accept');
            
            switch choice
                case 'Accept'
                    obj.intervallist = tempIntervals;
                    for int=1:numel(obj.intervallist)
                        start = intLines(int);
                        stop  = intLines(int) + ...
                                (obj.intervallist(int).frames(2)-obj.intervallist(int).frames(1));
                        obj.(type)(int).(values) = data(start:stop,2:end);
                    end
                    importedData = true;    % set flag - intervals based on import
                case 'Cancel'
                    return;                 % do nothing
            end
            
        end
        
        % generates post-track report, with bad frames
        function [ ] = generateReport(obj)
            intervalstr = 'Intervals of uncertainty:\n\n';
            hrepfig = figure;
            hrepax = axes('Parent',hrepfig,'Units','normalized','OuterPosition',[0,0,0.7,1],...
                        'FontUnits','normalized','FontSize',BFPClass.reportfontsize);
            hold(hrepax,'on');
            obj.plotTracks( hrepax, obj.minFrame, obj.maxFrame, true,true,'Style','M');
            set(hrepax, 'FontUnits','normalized','FontSize',BFPClass.reportfontsize);
            xlabel( hrepax, 'Time [frames]', 'FontUnits','normalized','FontSize',BFPClass.reportfontsize);
            ylabel( hrepax, 'Metric [r.u.]', 'FontUnits','normalized','FontSize',BFPClass.reportfontsize);
            title( hrepax, 'Detection metrics', 'FontUnits','normalized','FontSize',BFPClass.reportfontsize);
            
            for int=1:numel(obj.intervallist)
                ffrm = obj.intervallist(int).frames(1);
                %lfrm = obj.intervallist(int).frames(2);
                ffrm = ffrm-1;
                hold(hrepax,'on');
                badBeads = fillHoles(obj.beadPositions(int).bads);
                badPips  = fillHoles(obj.pipPositions(int).bads);
                badUni   = unifyIntervals(badBeads,badPips,obj.intervallist(int).frames);
                platPlot(badBeads,obj.metric,'r');
                platPlot(badPips,obj.correlation,'b');
                for bu=1:size(badUni,1)
                    intervalstr = sprintf(strcat(intervalstr,'\n','[',num2str(badUni(bu,1)),':',num2str(badUni(bu,2)),']'));
                end
            end
            
            if strcmp(intervalstr,'Intervals of uncertainty:\n\n');
                intervalstr = 'Tracking metrics were robust during the whole tracked interval.';
            end
            
            generalstr = (strjoin({'This report provides a post-tracking information. It highlights the',...
                'intervals, where the tracking metrics underperformed. It can be caused by partial',...
                'obscuring or, more likely, changes in contrast. In the intervals with different contrast,',...
                'the tracking must be performed using different pipette pattern. Please note, that forces',...
                'calculated using different patterns may be incompatible, beacause of a different reference point.',...
                'It can be challenging to achieve stable and compliant calibration in such cases.',...
                'Generally, it would be necessary to obtain an interval, where contrast changes, but',...
                'probe is inactive, and then to adjoin the force readings by an appropriate selection of',...
                '(no-load) frames of referential distance. You can still track video using the same pattern over',...
                'disjoined intervals, as long as the tracked pattern (i.e. its contrast) recovers,'...
                'forces calculated in such way are fully compatible.',...
                'Intervals of sub-threshold metrics reading follow.'}));
            
            hinfopanel = uipanel('Parent',hrepfig,'Units','normalized','Position',[0.7,0,0.3,1],...
                'BorderType','line','FontWeight','bold','Title','Post-detection summary');
                         uicontrol('Parent',hinfopanel,'Units','normalized','Position',[0,0.6,1,0.4],...
                'Style','text', 'String', generalstr,'HorizontalAlignment','left'); 
                         uicontrol('Parent',hinfopanel,'Units','normalized','Position',[0,0,1,0.6],...
                'Style','text', 'String', intervalstr,'HorizontalAlignment','left',...
                'FontWeight','bold','TooltipString','Unified intervals of bad frames of tracking the bead and the pipette');
            
            % plots plateaus of bad bead and pipette frames
            function [] = platPlot(bads,thresh,colour)
                for b=1:size(bads,1)
                    plot(hrepax, ffrm+bads(b,1):ffrm+bads(b,2), thresh*ones(1,bads(b,2)-bads(b,1)+1),strcat('-',colour),'LineWidth',2 );
                    pos = [ (ffrm+(bads(b,1)+bads(b,2))/2), thresh ];
                    if(mod(b,2)==0); va='bottom';else va='top'; end;
                    text( 'Parent', hrepax, 'String', strcat('[',num2str(ffrm+bads(b,1)),':',num2str(ffrm+bads(b,2)),']'), ...
                               'Units', 'data', 'Position', pos, 'Margin', 4, 'interpreter', 'latex', ...
                               'LineStyle','none', 'HitTest','off','FontUnits','normalized','FontSize',BFPClass.labelfontsize,...
                               'Color',colour, 'VerticalAlignment',va, 'HorizontalAlignment','center');
                end
            end
            
        end
        
        
        % calculates values of RBC stiffness ('k') and its uncertainty ('Dk')
        function [ ] = getStiffness(obj)
            % Rg - radius of RBC
            % Rp - radius of pipette
            % Rc - contact radius
            
            % relative radii
            rp = obj.Rp/obj.Rg;
            rc = obj.Rc/obj.Rg;

            % error of relative radii
            Drp = rp * ( (obj.DR/obj.Rp)^2 + (obj.DR/obj.Rg)^2 )^0.5;
            Drc = rc * ( (obj.DR/obj.Rc)^2 + (obj.DR/obj.Rg)^2 )^0.5;

            % force calculation denominator, inversed
            denom = 1/ (log(4/rc/rp) - (1 - 0.25*rp - 3/8*rp^2 + rc^2));

            % value of RBC stiffness
            obj.k = 0.5 * obj.Rp * obj.P * pi / (1 - rp) * denom;

            % partial derivative of stiffness by rp, rc; divided by k
            DkDrp = (1/(1 - rp) + 0.25 * (rc/rp - (1 + 3*rp) ) * denom);
            DkDrc = ( 0.25 * rp/rc + 2*rc )  * denom;

            % uncertainty of RBC stiffness 'Dk'
            obj.Dk = obj.k * (  (obj.DP/obj.P)^2 + (obj.DR/obj.Rp)^2 + (DkDrp*Drp)^2 + (DkDrc*Drc)^2 )^0.5;
        end
        
        % distance units transformations          
        function [um] = px2um(obj,px); um = px * obj.P2M; end
        
        function [px] = um2px(obj,um); px = um / obj.P2M; end
        
    end
    
    methods (Access = private)
    
        % called by other functions to delete data (e.g. before other data
        % are imported); might be changed to eraseByFrame, if appropriate
        function erase(obj,type)
            
            inp = inputParser();
            expectedTypes = { 'force', 'pipPositions', 'beadPositions', 'intervallist' }; % list of possible data to erase
            
            addRequired(inp,'type', @(x) any(validatestring(x,expectedTypes)));
            
            inp.parse(type);
            type = inp.Results.type;
            % ==================================
            
            obj.(type) = [];
            
        end
        
    end
    
end


% ================ CLASS RELATED FUNCTIONS =========================
% fills gaps between reported bad frames, to estimate bad intervals
function [badInts] = fillHoles(badFrames)
    inds = find(badFrames);
    ne   = numel(badFrames);
    for i=inds % dilate all trues -3:+3
        badFrames(max(i-3,1):min(i+3,ne)) = true;
    end;
    badInts = findIntervals(badFrames);

    for int=size(badInts,1):-1:1    % prune lone standing badFrames
        if badInts(int,2)-badInts(int,1) <= 7; badInts(int,:) = [];
        else % erode dilated frames
            badInts(int,1) = max(badInts(int,1)+3,1);
            badInts(int,2) = min(badInts(int,2)-3,ne);
        end;
    end            
end

% unifies intervals in list1,list2 within scope of limits
function [unified] = unifyIntervals(list1,list2,limits)
    boolint = false(limits(2)-limits(1)+1,1);
    list = [list1;list2];
    for l=1:size(list,1)
        e = list(l,:);
        boolint(e(1):e(2)) = true;
    end
    unified = findIntervals(boolint);
    unified = unified + limits(1)-1;
end

% helper function to find indices of interval ends for boolean array
function [ints] = findIntervals(values)
    ne = numel(values);
    ints = [];
    if any(find(values))
        difValues = diff(values);
        if values(1) % starts with interval
            ints(:,1) = [1;(find(difValues==1)+1)];
        else
            ints(:,1) = (find(difValues==1)+1);
        end;
        if values(end)
            ints(:,2) = [(find(difValues==-1));ne];
        else
            ints(:,2) = find(difValues==-1);
        end;
    end
end

