import mtwin.web.Handler;

class App {

	public static var database : sys.db.Connection;
	public static var session : db.Session;
	public static var user : db.User;
	public static var request : mtwin.web.Request;
	public static var context : Dynamic;
	public static var langFlags : db.Lang -> Bool;
	public static var langSelected : db.Lang;

	static var template : templo.Loader;

	static function sendNoCacheHeaders() {
		try {
			neko.Web.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
			neko.Web.setHeader("Pragma", "no-cache");
			neko.Web.setHeader("Expires", "-1");
			neko.Web.setHeader("P3P", "CP=\"ALL DSP COR NID CURa OUR STP PUR\"");
			neko.Web.setHeader("Content-Type", "text/html; Charset=UTF-8");
			neko.Web.setHeader("Expires", "Mon, 26 Jul 1997 05:00:00 GMT");
		} catch( e : Dynamic ) {
		}
	}

	public static function prepareTemplate( t : String ) {
		templo.Loader.OPTIMIZED = Config.DEBUG == false;
		templo.Loader.BASE_DIR = Config.TPL;
		templo.Loader.TMP_DIR = Config.TPL + "../tmp/";
		sendNoCacheHeaders();
		template = new templo.Loader(t);
	}

	static function executeTemplate() {
		var result = template.execute(context);
		sendNoCacheHeaders();
		neko.Lib.print(result);
	}

	static function redirect( url:String ) {
		template = null;
		sendNoCacheHeaders();
		neko.Web.redirect(url);
	}

	static function initLang() {
		if( Config.get("no_auto_lang","") == "1" )
			return null;
		var ldata = neko.Web.getClientHeader("Accept-Language");
		var ldata = if( ldata == null ) [] else ldata.split(",");
		var r = ~/^ ?([a-z]+)(-[a-zA-Z]+)?(;.*)?$/;
		ldata.push(Config.LANG);
		for( l in ldata ) {
			if( !r.match(l) ) continue;
			var code = r.matched(1);
			if( code == null ) continue;
			var l = db.Lang.manager.byCode(code);
			if( l != null ) return l.id;
		}
		return null;
	}

	static function requireHttpAuth(){
		neko.Web.setReturnCode( 401 );
		neko.Web.setHeader("status","401 Authorization Required");
		neko.Web.setHeader("WWW-Authenticate","Basic realm=\"Please identify yourself\"");
	}
	
	static function mainLoop() {
		// init
		request = new mtwin.web.Request();
		context = {};
		var sid = request.get("sid");
		if( sid == null ) sid = neko.Web.getCookies().get("sid");
		session = db.Session.initialize(sid);
		if( session.data == null ) {
			try {
				session.lang = initLang();
				session.insert();
				neko.Web.setHeader("Set-Cookie", "sid="+session.sid+"; path=/");
			} catch( e : Dynamic ) {
				new handler.Main().setupDatabase();
				database.commit();
				throw "Database initialized";
			}
		}
		
		if( session.uid == null && Config.USE_HTACCESS ) {
			var auth = neko.Web.getAuthorization();
			if( auth == null ) {
				requireHttpAuth();
				return;
			}
			var u = db.User.manager.search({ name : auth.user },false).first();
			if( u == null || handler.Main.encodePass(auth.pass) != u.pass ) {
				requireHttpAuth();
				return;
			}
			App.session.setUser(u);
		}
		
		user = if( session.uid != null ) db.User.manager.get(session.uid) else null;
		langFlags = function(l) return true;
		langSelected = null;

		// execute
		var h = new handler.Main();
		var level = if( request.getPathInfoPart(0) == "index.n" ) 1 else 0;
		try {
			h.dispatch(request,level);
		} catch( e : ActionError ) {
			switch( e ) {
			case ActionReservedToLoggedUsers:
				session.setError(Text.get.err_must_login);
			case UnknownAction(a):
				session.setError(Text.get.err_unknown_action,{ action : StringTools.htmlEscape(neko.Web.getURI()) });
			default:
			}
			redirect("/");
		} catch( e : handler.Action ) {
			switch( e ) {
			case Goto(url):
				redirect(url);
			case Error(url,err,params):
				database.rollback();
				sys.db.Manager.cleanup();
				session = db.Session.initialize(sid);
				if( user != null ) user = db.User.manager.get(user.id);
				session.setError(err,params);
				session.update();
				redirect(url);
			case Done(url,conf,params):
				session.setMessage(conf,params);
				redirect(url);
			}
		}
		if( user != null )
			user.update();
		if( template != null )
			initContext();
		session.update();
		if( template != null )
			executeTemplate();
	}

	static function initDatabase( params : String ) {
		var m = ~/^mysql:\/\/(.*):(.*)@(.*):(.*)\/(.*)$/;
		if( !m.match(params) )
			throw "Invalid format "+params;
		return sys.db.Mysql.connect({
			user : m.matched(1),
			pass : m.matched(2),
			host : m.matched(3),
			port : Std.parseInt(m.matched(4)),
			database : m.matched(5),
			socket : null
		});
	}

	static function initContext() {
		var style = Config.get("style", "default");
		if( session != null && session.designStyle != null )
			style = session.designStyle;
		context.user = user;
		context.session = session;
		context.request = request;
		var config = {
			title : Config.get("title"),
			style : style,
			url : Config.get("url"),
			gsearch : Config.get("gsearch",""),
		};
		if( config.gsearch == "" )
			config.gsearch = null;
		if( context.config == null )
			context.config = config;
		else
			for( f in Reflect.fields(config) )
				Reflect.setField(context.config, f, Reflect.field(config, f));

		// allow database failures here
		context.links = function(n:Int) return try db.Link.manager.search($kind == n,{ orderBy : [-priority,id] },false) catch( e : Dynamic ) new List();
		context.langs = try db.Lang.manager.all(false) catch( e : Dynamic ) new List();
		context.section = Config.getSection;
		var parts = neko.Web.getURI().split("/");
		context.current_url = parts[1] == "index.n" ? "/" : "/" + parts[1];
		
		// body class
		var userClass = user == null ? "offline" : user.group.name;
		var bodyClass = "user_" + userClass;
		if( context.config.cssClass != null )
			bodyClass += " " + context.config.cssClass;
		context.bodyClass = bodyClass;
		
		// which design mtt to choose
		if( context.design_mtt == null ) {
			var customDesign = "design_" + style + ".mtt";
			context.design_mtt = if( neko.FileSystem.exists(Config.TPL+customDesign) ) customDesign else "design.mtt";
		}
		
		// uri
		if( request == null )
			context.uri = "/";
		else {
			var uri = request.getURI();
			if( request.exists("path") )
				uri += "?path="+request.get("path");
			context.uri = uri;
		}
		context.dateFormat = function(d,fmt) {
			return DateTools.format(d,fmt);
		};
		context.lang_classes = function(l) {
			#if php
			return "off";
			#end
			var f = if( langFlags == null ) true else langFlags(l);
			return (f ? "on" : "off") + ((l == langSelected) ? " current" : "");
		};
		if( session != null && session.notification != null ) {
			context.notification = session.notification;
			session.notification = null;
		}
	}

	static function errorHandler( e : Dynamic ) {
		try {
			prepareTemplate("error.mtt");
			context = {};
			initContext();
			context.error = Std.string(e);
			context.stack = haxe.Stack.toString(haxe.Stack.exceptionStack());
			executeTemplate();
		} catch( e : Dynamic ) {
			neko.Lib.rethrow(e);
		}
	}

	static function cleanup() {
		if( database != null ) {
			database.close();
			database = null;
		}
		template = null;
		session = null;
		user = null;
		request = null;
		context = null;
		langFlags = null;
		langSelected = null;
	}

	static function main() {
		if( !neko.Sys.setTimeLocale(Text.get.locale1) )
			neko.Sys.setTimeLocale(Text.get.locale2);
		try {
			database = initDatabase(Config.get("db"));
		} catch( e : Dynamic ) {
			errorHandler(e);
			cleanup();
			return;
		}
		sys.db.Transaction.main(database, mainLoop, errorHandler);
		database = null; // already closed
		cleanup();
	}

}
