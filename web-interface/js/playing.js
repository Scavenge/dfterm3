dfterm3_playing = function() {
    // imports
    var do_after = dfterm3_timings.do_after;
    var seconds = dfterm3_timings.seconds;
    var fade_out = dfterm3_timings.fade_out;
    var fade_in = dfterm3_timings.fade_in;

    var exports = { };

    // protocol message types.
    var SCREEN_DATA = 1;
    var JSON_DATA = 2;

    if ( WebSocket === undefined ) {
        exports.websockets_are_supported = false;
        return exports;
    }
    exports.websockets_are_supported = true;

    // Call this when you want to connect to Dfterm3.
    exports.play = function( host           // Where is Dfterm3? This is a
                                            // WebSocket address, e.g.
                                            // "ws://127.0.0.1:8000/"
                           , host_dom_element
                                              // ^ The DOM element inside which
                                              // all the game stuff will be
                                              // put in.
                           ) {
        var terminal_dom_element = document.createElement("div");
        var title = document.createElement("span"); // title above the terminal
                                                    // itself.
        var terminal = undefined;                  // The terminal. Inside this
                                                   // you can see the actual
                                                   // game.
        var br_element = document.createElement("br"); // separates title from
                                                       // the game
        var second_br_element = document.createElement("br"); // separates game
                                                              // from whatever
                                                              // comes after it
        var status_element = document.createElement("span");

        var cover = document.createElement("div");
        cover.setAttribute("class", "cover");

        var showCover = function() {
            cover.style.display = "block";
        }
        var hideCover = function() {
            cover.style.display = "none";
        }

        host_dom_element.appendChild( cover );
        host_dom_element.appendChild( terminal_dom_element );

        status_element.textContent =
            "Trying to make a connection to Dfterm3 server..."
        status_element.setAttribute( "class"
                                   , "dfterm3_connection_status_element_good" );

        title.textContent = "Dwarf Fortress v0.31.11"

        var status = function( str, badness ) {
            fade_status_in_after( 0.0 );
            status_element.textContent = str;
            if ( badness ) {
                status_element.setAttribute(
                          "class"
                        , "dfterm3_connection_status_element_bad" );
            } else {
                status_element.setAttribute(
                          "class"
                        , "dfterm3_connection_status_element_good" );
            }
            fade_status_out_after( 2.0 );
        }

        var fade_status_out_after = function ( time ) {
            fade_out( status_element, time );
        }

        var fade_status_in_after = function ( time ) {
            fade_in( status_element, time );
        }

        // Removes the terminal elements from the page, if they are there.
        // Otherwise does nothing.
        var stopTerminal = function () {
            if ( !terminal ) {
                return;
            }
            terminal_dom_element.removeChild( terminal.getDOMObject() );
            terminal_dom_element.removeChild( title );
            terminal_dom_element.removeChild( br_element );
            terminal_dom_element.removeChild( second_br_element );
            terminal = undefined;
        }

        // Starts a terminal on the page. Removes the old terminal if it is
        // there.
        var startTerminal = function( w, h ) {
            stopTerminal();
            terminal = dfterm3_terminal.createTerminal( w, h );

            terminal_dom_element.appendChild( title );
            terminal_dom_element.appendChild( br_element );
            terminal_dom_element.appendChild( terminal.getDOMObject() );
            terminal_dom_element.appendChild( second_br_element );
        }

        title.setAttribute("class", "dfterm3_terminal_title_bar");

        terminal_dom_element.appendChild( status_element );

        // This function parses the WebSocket data received from Dfterm3 when
        // it is screen data. It updates the terminal (if there is one).
        var handleScreenData = function( array ) {
            var array_view = new Uint8Array( array, 1 );
            var w = (array_view[0] << 8) | array_view[1];
            var h = (array_view[2] << 8) | array_view[3];
            if ( !terminal ) {
                return;
            }
            terminal.resize( w, h );
            var num_elements = (array_view[4] << 24) |
                               (array_view[5] << 16) |
                               (array_view[6] << 8) |
                               (array_view[7]);

            for ( var i = 0; i < num_elements; ++i ) {
                var offset = 8 + i*6;
                var cp437_code = array_view[offset];
                var colors = array_view[offset+1];
                var foreground_color = colors & 0x0f;
                var background_color = (colors & 0xf0) >> 4;
                var x = (array_view[offset+2] << 8) | array_view[offset+3];
                var y = (array_view[offset+4] << 8) | array_view[offset+5];
                terminal.setCP437CellAt( x, y, cp437_code
                                       , foreground_color
                                       , background_color );
            }
        }

        startTerminal( 80, 24 );
        showCover();

        var socket = new WebSocket( host );
        socket.onopen = function() {
            status("Connection established.", false );
            hideCover();
        }
        socket.onclose = function() {
            status("No connection to server.", true );
            showCover();
        }
        socket.onmessage = function(event) {
            var reader = new FileReader();
            reader.readAsArrayBuffer(event.data);
            reader.onload = function() {
                var array = reader.result;
                var array_view = new Uint8Array( array, 0, 1 );
                if ( array_view[0] == SCREEN_DATA ) {
                    handleScreenData( array );
                } else if ( array_view[0] == JSON_DATA ) {
                    // nothing yet.
                }
            }
        }
    }

    return exports;
}();
