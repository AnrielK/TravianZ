<h2><?php echo EARTHWALL ?></h2>
        <table class="new_building" cellpadding="1" cellspacing="1">
                <tbody><tr>
                        <td class="desc"><?php echo EARTHWALL_DESC ?></td>
                        <td rowspan="3" class="bimg">
                                <a href="#" onClick="return Popup(32,4);">
                                <img class="building g32" src="img/x.gif" alt="<?php echo EARTHWALL; ?>" title="<?php echo EARTHWALL; ?>" /></a>
                        </td>
                </tr>
                <tr>
                <?php
        $_GET['bid'] = 32;
        include("availupgrade.tpl");
        ?>
                </tr></tbody>
        </table>
